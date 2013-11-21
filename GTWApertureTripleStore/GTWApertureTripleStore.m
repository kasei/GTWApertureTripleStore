//
//  GTWApertureTripleStore.m
//  GTWApertureTripleStore
//
//  Created by Gregory Williams on 8/4/13.
//  Copyright (c) 2013 Gregory Todd Williams. All rights reserved.
//

#define IRI(i) [[GTWIRI alloc] initWithValue:i]
#define LITERAL(l) [[GTWLiteral alloc] initWithValue:l]
#define TRIPLE(s,p,o) [[GTWTriple alloc] initWithSubject:s predicate:p object:o]

#import <CommonCrypto/CommonCrypto.h>
#import "GTWApertureTripleStore.h"
#import "FMDatabaseAdditions.h"
#import "FMDatabasePool.h"
#import "FMDatabaseQueue.h"
#import <AddressBook/AddressBook.h>
#import <GTWSWBase/GTWSWBase.h>
#import <GTWSWBase/GTWIRI.h>
#import <GTWSWBase/GTWVariable.h>
#import <GTWSWBase/GTWLiteral.h>
#import <GTWSWBase/GTWTriple.h>
#import <SPARQLKit/SPKTree.h>

static NSString* rdftype        = @"http://www.w3.org/1999/02/22-rdf-syntax-ns#type";
static NSString* foafImage      = @"http://xmlns.com/foaf/0.1/Image";
static NSString* foafDepicts    = @"http://xmlns.com/foaf/0.1/depicts";
static NSString* geoLat         = @"http://www.w3.org/2003/01/geo/wgs84_pos#lat";
static NSString* geoLong        = @"http://www.w3.org/2003/01/geo/wgs84_pos#long";
static NSString* dctSpatial     = @"http://purl.org/dc/terms/spatial";
static NSString* foafName       = @"http://xmlns.com/foaf/0.1/name";
static NSString* foafMboxSha    = @"http://xmlns.com/foaf/0.1/mbox_sha1sum";
static NSString* foafPerson     = @"http://xmlns.com/foaf/0.1/Person";

@interface GTWApertureTripleStoreQueryPlan : GTWQueryPlan
@property NSSet* variables;
- (GTWApertureTripleStoreQueryPlan*) initWithBlock: (NSEnumerator* (^)(id<SPKTree, GTWQueryPlan> plan, id<GTWModel> model))block bindingVariables: (NSSet*) vars;
@end
@implementation GTWApertureTripleStoreQueryPlan
- (GTWApertureTripleStoreQueryPlan*) initWithBlock: (NSEnumerator* (^)(id<SPKTree, GTWQueryPlan> plan, id<GTWModel> model))block bindingVariables: (NSSet*) vars {
    if (self = [self initWithType:kPlanCustom arguments:nil]) {
        self.value      = block;
        self.variables  = [vars copy];
    }
    return self;
}

- (NSSet*) inScopeVariables {
    return self.variables;
}

- (NSString*) description { return @"GTWApertureTripleStoreQueryPlan"; }
- (NSString*) conciseDescription { return @"GTWApertureTripleStoreQueryPlan"; }
- (NSString*) longDescription { return @"GTWApertureTripleStoreQueryPlan"; }
@end





@implementation GTWApertureTripleStore

+ (unsigned)interfaceVersion {
    return 0;
}

+ (NSString*) usage {
    return @"{ \"bundlepath\": <Path to Aperture Library.aplibrary file> }";
}

+ (NSDictionary*) classesImplementingProtocols {
    NSSet* set  = [NSSet setWithObjects:@protocol(GTWTripleStore), nil];
    return @{ (id)self: set };
}

+ (NSSet*) implementedProtocols {
    return [NSSet setWithObjects:@protocol(GTWTripleStore), nil];
}

- (instancetype) initWithDictionary: (NSDictionary*) dictionary {
    NSString* path  = dictionary[@"bundlepath"];
    if (!path) {
        NSArray *searchPaths;
        NSEnumerator *searchPathEnum;
        NSString *currPath;
        NSMutableArray *bundles = [NSMutableArray array];
        searchPaths = NSSearchPathForDirectoriesInDomains(NSPicturesDirectory, NSAllDomainsMask - NSSystemDomainMask, YES);
        searchPathEnum = [searchPaths objectEnumerator];
        while (currPath = [searchPathEnum nextObject]) {
            [bundles addObject: [currPath stringByAppendingPathComponent:@"Aperture Library.aplibrary"]];
        }
        if ([bundles count]) {
            path    = bundles[0];
        } else {
            return nil;
        }
    }
    return [self initWithApertureBundlePath:path];
}

- (instancetype) initWithApertureBundlePath: (NSString*) base {
    if (self = [super init]) {
        self.seenPeople = [NSMutableDictionary dictionary];
        self.faces  = [NSMutableDictionary dictionary];
        self.people = [NSMutableDictionary dictionary];
        self.base   = base;
        
        NSString* facesPath = [NSString stringWithFormat:@"%@/Database/apdb/Faces.db", base];
//        NSLog(@"%@", facesPath);
        //    NSString* base      = @"/Users/greg/Desktop/test-5.aplibrary";
        //    NSString* facesPath  = @"/Users/greg/Desktop/test-5.aplibrary/Database/apdb/Faces.db";
        self.facesdb = [FMDatabase databaseWithPath:facesPath];
        if (![self.facesdb open]) {
            NSLog(@"Could not open faces db.");
            return nil;
        }
        
        NSString* libraryPath = [NSString stringWithFormat:@"%@/Database/apdb/Library.apdb", base];
        //        NSLog(@"%@", libraryPath);
        //    NSString* libraryPath  = @"/Users/greg/Desktop/test-5.aplibrary/Database/apdb/Library.apdb";
        self.librarydb = [FMDatabase databaseWithPath:libraryPath];
        if (![self.librarydb open]) {
            NSLog(@"Could not open library db.");
            return nil;
        }
        
        NSString* propertiesPath = [NSString stringWithFormat:@"%@/Database/apdb/Properties.apdb", base];
        //        NSLog(@"%@", libraryPath);
        //    NSString* libraryPath  = @"/Users/greg/Desktop/test-5.aplibrary/Database/apdb/Library.apdb";
        self.propdb = [FMDatabase databaseWithPath:propertiesPath];
        if (![self.propdb open]) {
            self.propdb = nil;
        }
    }
    return self;
}

- (GTWIRI*) iriForPersonID: (NSString*) uid {
    NSString* uri   = [NSString stringWithFormat:@"tag:kasei.us,2013-05-12:%@", uid];
    return IRI(uri);
}

- (ABPerson*) matchPersonFromProperties: (NSDictionary*) props {
    static ABAddressBook* ab        = nil;
    if (!ab) {
        ab  = [ABAddressBook sharedAddressBook];
    }
    
    if (props[@"email"]) {
        ABSearchElement *matchingEmail = [ABPerson searchElementForProperty:kABEmailProperty
                                                                      label:nil
                                                                        key:nil
                                                                      value:props[@"email"]
                                                                 comparison:kABEqualCaseInsensitive];
        NSArray *peopleFound = [ab recordsMatchingSearchElement:matchingEmail];
        if ([peopleFound count] == 1) {
            return peopleFound[0];
        }
    }
    return nil;
}

- (NSArray*) getTriplesMatchingSubject: (id<GTWTerm>) s predicate: (id<GTWTerm>) p object: (id<GTWTerm>) o error:(NSError **)error {
    NSMutableArray* array   = [NSMutableArray array];
    [self enumerateTriplesMatchingSubject:s predicate:p object:o usingBlock:^(id<GTWTriple> t){
        [array addObject:t];
    } error:error];
    return array;
}

- (void) loadPeopleAndFaces {
    if ([self.faces count])
        return;
    
    @autoreleasepool {
        //        [self enumeratePhotoFacePeopleFromDatabase:self.facesdb usingBlock:filter];
        FMDatabase* db  = self.facesdb;
        FMResultSet *rs = [db executeQuery:@"SELECT faceKey, name, email FROM RKFaceName ORDER BY fullName"];
        if (rs) {
            while ([rs next]) {
                NSNumber* pid   = [rs objectForColumnName:@"faceKey"];
                NSString* name  = [rs stringForColumn:@"name"];
                NSString* email = [rs stringForColumn:@"email"];
                if (!email)
                    email   = @"";
                [self.people setObject:@{@"name": name, @"email": email} forKey:pid];
                // just print out what we've got in a number of formats.
                //            NSLog(@"%d %@ %@",
                //                  [rs intForColumn:@"faceKey"],
                //                  [rs stringForColumn:@"name"],
                //                  [rs stringForColumn:@"email"]
                //            );
            }
            [rs close];
        } else {
            NSLog(@"%@", [db lastErrorMessage]);
        }
    }
    @autoreleasepool {
        //        [self enumeratePhotoFaceDataFromDatabase:self.facesdb usingBlock:filter];
        FMDatabase* db  = self.facesdb;
        FMResultSet *rs = [db executeQuery:@"SELECT masterUuid AS photoid, faceKey FROM RKDetectedFace"];
        if (rs) {
            while ([rs next]) {
                NSString* photo = [rs objectForColumnName:@"photoid"];
                NSNumber* pid   = [rs objectForColumnName:@"faceKey"];
                NSMutableSet* set   = [self.faces objectForKey:photo];
                if (!set) {
                    set = [NSMutableSet set];
                    [self.faces setObject:set forKey:photo];
                }
                [set addObject:pid];
            }
            [rs close];
        } else {
            NSLog(@"%@", [db lastErrorMessage]);
        }
        
    }
}

- (BOOL) enumerateTriplesMatchingSubject: (id<GTWTerm>) s predicate: (id<GTWTerm>) p object: (id<GTWTerm>) o usingBlock: (void (^)(id<GTWTriple> t)) block error:(NSError **)error {
    void (^filter)(id<GTWTriple> t)  = ^(id<GTWTriple> t){
        if (
            (!s || [s conformsToProtocol:@protocol(GTWVariable)] || [s isEqual:t.subject]) &&
            (!p || [p conformsToProtocol:@protocol(GTWVariable)] || [p isEqual:t.predicate]) &&
            (!o || [o conformsToProtocol:@protocol(GTWVariable)] || [o isEqual:t.object])
            ) {
            block(t);
        }
        return;
    };
    
    @autoreleasepool {
//        [self enumeratePhotoFacePeopleFromDatabase:self.facesdb usingBlock:filter];
        FMDatabase* db  = self.facesdb;
        FMResultSet *rs = [db executeQuery:@"SELECT faceKey, name, email FROM RKFaceName ORDER BY fullName"];
        if (rs) {
            while ([rs next]) {
                NSNumber* pid   = [rs objectForColumnName:@"faceKey"];
                NSString* name  = [rs stringForColumn:@"name"];
                NSString* email = [rs stringForColumn:@"email"];
                if (!email)
                    email   = @"";
                [self.people setObject:@{@"name": name, @"email": email} forKey:pid];
                // just print out what we've got in a number of formats.
                //            NSLog(@"%d %@ %@",
                //                  [rs intForColumn:@"faceKey"],
                //                  [rs stringForColumn:@"name"],
                //                  [rs stringForColumn:@"email"]
                //            );
            }
            [rs close];
        } else {
            NSLog(@"%@", [db lastErrorMessage]);
        }
    }
    
    @autoreleasepool {
//        [self enumeratePhotoFaceDataFromDatabase:self.facesdb usingBlock:filter];
        FMDatabase* db  = self.facesdb;
        FMResultSet *rs = [db executeQuery:@"SELECT masterUuid AS photoid, faceKey FROM RKDetectedFace"];
        if (rs) {
            while ([rs next]) {
                NSString* photo = [rs objectForColumnName:@"photoid"];
                NSNumber* pid   = [rs objectForColumnName:@"faceKey"];
                NSMutableSet* set   = [self.faces objectForKey:photo];
                if (!set) {
                    set = [NSMutableSet set];
                    [self.faces setObject:set forKey:photo];
                }
                [set addObject:pid];
            }
            [rs close];
        } else {
            NSLog(@"%@", [db lastErrorMessage]);
        }

    }
    
    NSMutableDictionary* photoIRIs  = [NSMutableDictionary dictionary];
    @autoreleasepool {
//        [self enumeratePhotoDetailDataFromDatabase:self.librarydb usingBlock:filter];
        FMDatabase* db  = self.librarydb;
        FMResultSet *rs = [db executeQuery:@"SELECT uuid AS photoid, imagePath FROM RKMaster"];
        if (rs) {
            while ([rs next]) {
                NSString* photo = [rs objectForColumnName:@"photoid"];
                NSString* path  = [rs objectForColumnName:@"imagePath"];
                //            [photos setObject:@{@"path": path} forKey:photo];
                
                // path a foaf:Image
                NSString* photoPath = [NSString stringWithFormat:@"%@/Masters/%@", self.base, path];
                NSSet* set  = self.faces[photo];
                
                //            NSLog(@"Photo: %@", photoPath);
                
                GTWIRI* subject     = [[GTWIRI alloc] initWithValue:[NSString stringWithFormat:@"file://%@", photoPath]];
                photoIRIs[photo]    = subject;
                GTWIRI* predicate   = IRI(rdftype);
                GTWIRI* object      = IRI(foafImage);
                id<GTWTriple> t     = TRIPLE(subject, predicate, object);
                filter(t);
                
                for (id pid in set) {
                    NSDictionary* props = self.people[pid];
                    ABPerson* person = [self matchPersonFromProperties: props];
                    if (person) {
                        [self.seenPeople setObject:props forKey:(id<NSCopying>)person];
                        //                    NSString* name  = props[@"name"];
                        //                    NSLog(@"  - %@ (%@)", name, uri);
                        GTWIRI* predicate   = IRI(foafDepicts);
                        GTWIRI* object      = [self iriForPersonID:[person uniqueId]];
                        id<GTWTriple> t     = TRIPLE(subject, predicate, object);
                        filter(t);
                    }
                }
            }
            [rs close];
        } else {
            NSLog(@"%@", [db lastErrorMessage]);
        }
    }
    
    @autoreleasepool {
        FMDatabase* db      = self.librarydb;
        FMDatabase* propdb  = self.propdb;
//        FMResultSet *rs = [db executeQuery:@"SELECT masterUuid AS photoid, exifLatitude, exifLongitude FROM RKVersion WHERE exifLatitude IS NOT NULL AND exifLongitude IS NOT NULL"];
        FMResultSet *rs = [db executeQuery:@"SELECT masterUuid AS photoid, exifLatitude, exifLongitude, p.placeId, hasKeywords FROM RKVersion v LEFT JOIN RKPlaceForVersion p ON (p.versionId = v.modelId AND p.modelId IN (SELECT MAX(modelId) FROM RKPlaceForVersion GROUP BY versionId)) WHERE exifLatitude IS NOT NULL AND exifLongitude IS NOT NULL"];
        
        if (rs) {
            NSUInteger counter  = 0;
            while ([rs next]) {
                NSString* photo = [rs objectForColumnName:@"photoid"];
                GTWIRI* subject = photoIRIs[photo];
                if (subject) {
                    NSNumber* lat       = [rs objectForColumnName:@"exifLatitude"];
                    NSNumber* lon       = [rs objectForColumnName:@"exifLongitude"];
                    GTWIRI* geolat      = IRI(geoLat);
                    GTWIRI* geolong     = IRI(geoLong);
                    GTWIRI* spatial     = IRI(dctSpatial);
                    GTWIRI* foafname    = IRI(foafName);
                    GTWLiteral* la  = [GTWLiteral decimalLiteralWithValue:[lat doubleValue]];
                    GTWLiteral* lo  = [GTWLiteral decimalLiteralWithValue:[lon doubleValue]];
                    
                    GTWBlank* b  = [[GTWBlank alloc] initWithValue:[NSString stringWithFormat:@"B%lu", counter++]];
                    
                    id<GTWTriple> t;
                    t   = TRIPLE(subject, spatial, b);
                    filter(t);
                    
                    t   = TRIPLE(b, geolat, la);
                    filter(t);
                    
                    t   = TRIPLE(b, geolong, lo);
                    filter(t);
                    NSNumber* hasKeywords  = [rs objectForColumnName:@"hasKeywords"];
                    if (hasKeywords && [hasKeywords isKindOfClass:[NSNumber class]] && [hasKeywords boolValue]) {
                        
                    }
                    
                    id placeId  = [rs objectForColumnName:@"placeId"];
                    if (placeId && ![placeId isKindOfClass:[NSNull class]]) {
//                        NSLog(@"place: %@ (%p: %@)", placeId, placeId, [placeId class]);
                        if (propdb) {
                            FMResultSet* place  = [propdb executeQuery:@"SELECT defaultName FROM RKPlace WHERE modelId = ?", placeId];
                            if (place && [place next]) {
                                NSString* placeName = [place objectForColumnName:@"defaultName"];
                                if (placeName) {
                                    id<GTWTerm> name    = LITERAL(placeName);
                                    t   = TRIPLE(b, foafname, name);
//                                    NSLog(@"place: %@", t);
                                    filter(t);
                                }
                            }
                        }
                    }
                }
            }
        } else {
            NSLog(@"no result set for gps data");
        }
    }
    
    photoIRIs   = nil;
    
    @autoreleasepool {
    //    NSLog(@"People properties: %@", self.people);
        for (ABPerson* p in self.seenPeople) {
            id props    = [self.seenPeople objectForKey:p];
    //        NSLog(@"props: %@", props);
            NSString* name  = props[@"name"];
    //        NSString* email  = props[@"email"];
    //        NSLog(@"person unique ID: %@", [p uniqueId]);
            GTWIRI* subject     = [self iriForPersonID:[p uniqueId]];
            GTWIRI* foafname    = IRI(foafName);
            GTWIRI* foafmbox    = IRI(foafMboxSha);
            GTWIRI* Person  = IRI(foafPerson);
            GTWIRI* type     = IRI(rdftype);
            filter(TRIPLE(subject, type, Person));
            filter(TRIPLE(subject, foafname, LITERAL(name)));
            
            ABMultiValue *emails = [p valueForProperty:kABEmailProperty];
            NSUInteger i;
            for (i = 0; i < [emails count]; i++) {
                id email    = [emails valueAtIndex:i];
                NSString* value = [NSString stringWithFormat:@"mailto:%@", email];
                GTWLiteral* l   = [self sha1LiteralForString:value];
                filter(TRIPLE(subject, foafmbox, l));
            }
        }
    }
    return YES;
}

- (GTWLiteral*) sha1LiteralForString: (NSString*) value {
    const char *cstr = [value cStringUsingEncoding:NSUTF8StringEncoding];
    NSData *data = [NSData dataWithBytes:cstr length:value.length];
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG) data.length, digest);
    NSMutableString* output = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for(int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++)
        [output appendFormat:@"%02x", digest[i]];
    return [[GTWLiteral alloc] initWithValue: output];
}

#pragma mark - Photo Query Planning

- (NSEnumerator*) imageTypeTriplesBindingVariable: (NSString*) var {
    NSMutableArray* results = [NSMutableArray array];
    @autoreleasepool {
        FMDatabase* db  = self.librarydb;
        FMResultSet *rs = [db executeQuery:@"SELECT uuid AS photoid, imagePath FROM RKMaster"];
        if (rs) {
            while ([rs next]) {
                NSString* path  = [rs objectForColumnName:@"imagePath"];
                NSString* photoPath = [NSString stringWithFormat:@"%@/Masters/%@", self.base, path];
                GTWIRI* subject     = [[GTWIRI alloc] initWithValue:[NSString stringWithFormat:@"file://%@", photoPath]];
                [results addObject:@{var: subject}];
            }
            [rs close];
        }
    }
    return [results objectEnumerator];
}

- (NSEnumerator*) imageGeoTriplesBindingImage: (NSString*) imageVar latitude: (NSString*) latVar longitude: (NSString*) lonVar {
    NSMutableArray* results = [NSMutableArray array];
    NSMutableDictionary* photoIRIs  = [NSMutableDictionary dictionary];
    @autoreleasepool {
        FMDatabase* db  = self.librarydb;
        FMResultSet *rs = [db executeQuery:@"SELECT uuid AS photoid, imagePath FROM RKMaster"];
        if (rs) {
            while ([rs next]) {
                NSString* photo = [rs objectForColumnName:@"photoid"];
                NSString* path  = [rs objectForColumnName:@"imagePath"];
                NSString* photoPath = [NSString stringWithFormat:@"%@/Masters/%@", self.base, path];
                GTWIRI* subject     = [[GTWIRI alloc] initWithValue:[NSString stringWithFormat:@"file://%@", photoPath]];
                photoIRIs[photo]    = subject;
            }
            [rs close];
        } else {
            NSLog(@"%@", [db lastErrorMessage]);
        }
    }
    @autoreleasepool {
        FMDatabase* db      = self.librarydb;
        FMResultSet *rs = [db executeQuery:@"SELECT masterUuid AS photoid, exifLatitude, exifLongitude FROM RKVersion v WHERE exifLatitude IS NOT NULL AND exifLongitude IS NOT NULL"];
        
        if (rs) {
            while ([rs next]) {
                NSString* photo = [rs objectForColumnName:@"photoid"];
                GTWIRI* subject = photoIRIs[photo];
                if (subject) {
                    NSNumber* lat       = [rs objectForColumnName:@"exifLatitude"];
                    NSNumber* lon       = [rs objectForColumnName:@"exifLongitude"];
                    GTWLiteral* la  = [GTWLiteral decimalLiteralWithValue:[lat doubleValue]];
                    GTWLiteral* lo  = [GTWLiteral decimalLiteralWithValue:[lon doubleValue]];
                    
                    [results addObject:@{ imageVar: subject, latVar: la, lonVar: lo }];
                }
            }
        } else {
            NSLog(@"no result set for gps data");
        }
    }
    photoIRIs   = nil;
    return [results objectEnumerator];
}

- (NSEnumerator*) imageDepictionTriplesBindingImage: (NSString*) image depiction: (NSString*) depiction {
    [self loadPeopleAndFaces];
    NSMutableArray* results = [NSMutableArray array];
    @autoreleasepool {
        FMDatabase* db  = self.facesdb;
        FMResultSet *rs = [db executeQuery:@"SELECT masterUuid AS photoid, faceKey FROM RKDetectedFace"];
        if (rs) {
            while ([rs next]) {
                NSString* photo = [rs objectForColumnName:@"photoid"];
                NSNumber* pid   = [rs objectForColumnName:@"faceKey"];
                NSMutableSet* set   = [self.faces objectForKey:photo];
                if (!set) {
                    set = [NSMutableSet set];
                    [self.faces setObject:set forKey:photo];
                }
                [set addObject:pid];
            }
            [rs close];
        } else {
            NSLog(@"%@", [db lastErrorMessage]);
        }
        
    }
    @autoreleasepool {
        FMDatabase* db  = self.librarydb;
        FMResultSet *rs = [db executeQuery:@"SELECT uuid AS photoid, imagePath FROM RKMaster"];
        if (rs) {
            while ([rs next]) {
                NSString* photo = [rs objectForColumnName:@"photoid"];
                NSString* path  = [rs objectForColumnName:@"imagePath"];
                NSString* photoPath = [NSString stringWithFormat:@"%@/Masters/%@", self.base, path];
                NSSet* set  = self.faces[photo];
                GTWIRI* subject     = [[GTWIRI alloc] initWithValue:[NSString stringWithFormat:@"file://%@", photoPath]];
                for (id pid in set) {
                    NSDictionary* props = self.people[pid];
                    ABPerson* person = [self matchPersonFromProperties: props];
                    if (person) {
                        GTWIRI* object      = [self iriForPersonID:[person uniqueId]];
                        [results addObject:@{image: subject, depiction: object}];
                    }
                }
            }
            [rs close];
        }
    }
    return [results objectEnumerator];
}

- (id<SPKTree,GTWQueryPlan>) queryPlanForAlgebra: (id<SPKTree>) algebra usingDataset: (id<GTWDataset>) dataset withModel: (id<GTWModel>) model options: (NSDictionary*) options {
//    NSLog(@"Aperture triple store trying to plan algebra %@", [algebra conciseDescription]);
    NSArray* graphs = [dataset defaultGraphs];
    NSMutableSet* graphSet  = [NSMutableSet set];
    for (id<GTWTerm> g in graphs) {
        [graphSet addObject:g.value];
    }
    NSArray* datasetGraphs  = [dataset defaultGraphs];
//    NSLog(@"aperture store planning for graphs: %@", graphSet);
    if ([graphSet count] == 1 && [datasetGraphs count] == 1) {
        NSString* g = [graphSet anyObject];
        GTWIRI* dg  = datasetGraphs[0];
        if ([g isEqualToString:dg.value]) {
            if ([algebra.treeTypeName isEqualToString:@"TreeTriple"]) {
                id<GTWTriple> triple    = algebra.value;
//                NSLog(@"Aperture triple store planning triple %@; options: %@", triple, options);
                id<GTWTerm> s   = triple.subject;
                id<GTWTerm> p   = triple.predicate;
                id<GTWTerm> o   = triple.object;
                
                // If predicate is an IRI that we don't produce, return the empty query plan
                if ([p isKindOfClass:[GTWIRI class]]) {
                    NSSet* recognized   = [NSSet setWithObjects:rdftype, foafDepicts, geoLat, geoLong, dctSpatial, foafName, foafMboxSha, nil];
                    if (![recognized containsObject:p.value]) {
                        return [[GTWQueryPlan alloc] initWithType:kPlanEmpty arguments:nil];
                    }
                }
                
                if ([s isKindOfClass:[GTWVariable class]]) {
                    if ([p.value isEqualToString:rdftype] && [o.value isEqualToString:foafImage]) {
                        // Optimize for the triple pattern { ?s a foaf:Image }
                        NSSet* variables    = [NSSet setWithObject:s];
                        id<SPKTree,GTWQueryPlan> plan   = [[GTWApertureTripleStoreQueryPlan alloc] initWithBlock:^NSEnumerator*(id<SPKTree, GTWQueryPlan> plan, id<GTWModel> model){
                            return [self imageTypeTriplesBindingVariable:s.value];
                        } bindingVariables:variables];
                        return plan;
                    }
                    if ([p.value isEqualToString:foafDepicts] && [o isKindOfClass:[GTWVariable class]]) {
                        // Optimize for the triple pattern { ?s foaf:depiction ?d }
                        NSSet* variables    = [NSSet setWithObjects:s, o, nil];
                        id<SPKTree,GTWQueryPlan> plan   = [[GTWApertureTripleStoreQueryPlan alloc] initWithBlock:^NSEnumerator*(id<SPKTree, GTWQueryPlan> plan, id<GTWModel> model){
                            return [self imageDepictionTriplesBindingImage:s.value depiction:o.value];
                        } bindingVariables:variables];
                        return plan;
                    }
                }
            }
        } else if ([algebra.treeTypeName isEqualToString:@"AlgebraBGP"]) {
            NSMutableDictionary* spatialTriples = [NSMutableDictionary dictionary];
            NSMutableDictionary* latTriples     = [NSMutableDictionary dictionary];
            NSMutableDictionary* longTriples    = [NSMutableDictionary dictionary];
            NSMutableSet* nonGeoBnodeTriples    = [NSMutableSet set];
            //        NSLog(@"Aperture trying to plan BGP:");
            for (id<SPKTree> tripleTree in algebra.arguments) {
                if ([tripleTree.treeTypeName isEqualToString:@"TreeTriple"]) {
                    //                NSLog(@"-> %@", tripleTree);
                    id<GTWTriple> triple    = tripleTree.value;
                    id<GTWTerm> s   = triple.subject;
                    id<GTWTerm> o   = triple.object;
                    if ([s isKindOfClass:[GTWVariable class]] && [o isKindOfClass:[GTWVariable class]]) {
                        id<GTWTerm> p   = triple.predicate;
                        if ([p.value isEqualToString:dctSpatial] && [o.value hasPrefix:@".b"]) {
                            spatialTriples[o]   = tripleTree;
                        } else if ([p.value isEqualToString:geoLat]) {
                            latTriples[s] = tripleTree;
                        } else if ([p.value isEqualToString:geoLong]) {
                            longTriples[s] = tripleTree;
                        } else {
                            NSSet* vars = [tripleTree inScopeVariables];
                            [nonGeoBnodeTriples addObjectsFromArray:[vars allObjects]];
                        }
                    } else {
                        NSSet* vars = [tripleTree inScopeVariables];
                        [nonGeoBnodeTriples addObjectsFromArray:[vars allObjects]];
                    }
                }
            }
            
            //        NSLog(@"%@\n%@\n%@", spatialTriples, latTriples, longTriples);
            NSMutableSet* otherTriples  = [NSMutableSet setWithArray:algebra.arguments];
            NSMutableArray* plans       = [NSMutableArray array];
            for (id<GTWTerm> spatial in spatialTriples) {
                id<SPKTree> spatialTripleTree   = spatialTriples[spatial];
                id<GTWTriple> spatialTriple = spatialTripleTree.value;
                id<GTWTerm> image           = spatialTriple.subject;
                //            NSLog(@"spatial triple: %@", spatialTriple);
                
                id<SPKTree> latTripleTree   = latTriples[spatial];
                id<GTWTriple> latTriple     = latTripleTree.value;
                
                id<SPKTree> lonTripleTree   = longTriples[spatial];
                id<GTWTriple> lonTriple     = lonTripleTree.value;
                
                id<GTWTerm> lat = latTriple.object;
                id<GTWTerm> lon = lonTriple.object;
                if (lat && lon) {
                    if ([nonGeoBnodeTriples containsObject:spatial]) {
                        //                    NSLog(@"cannot optimize geo BGP because the spatial node is used in unrecognized triples");
                    } else {
                        //                    NSLog(@"-> found lat and lon variables for spatial node %@ (%@, %@)", spatial, lat, lon);
                        NSSet* variables    = [NSSet setWithObjects:image, lat, lon, nil];
                        id<SPKTree,GTWQueryPlan> plan   = [[GTWApertureTripleStoreQueryPlan alloc] initWithBlock:^NSEnumerator*(id<SPKTree, GTWQueryPlan> plan, id<GTWModel> model){
                            return [self imageGeoTriplesBindingImage:image.value latitude:lat.value longitude:lon.value];
                        } bindingVariables:variables];
                        
                        [otherTriples removeObject:spatialTriples[spatial]];
                        [otherTriples removeObject:latTripleTree];
                        [otherTriples removeObject:lonTripleTree];
                        
                        {
                            // Remove any triple patterns matching { ?image a foaf:Image } for images that we're producing geo data for, because the typing is implicit
                            NSArray* otherCopy  = [otherTriples copy];
                            for (id<SPKTree> t in otherCopy) {
                                id<GTWTriple> triple     = t.value;
                                if ([triple.subject isEqual:image] && [triple.predicate isEqual:IRI(rdftype)] && [triple.object isEqual:IRI(foafImage)]) {
                                    [otherTriples removeObject:t];
                                }
                            }
                        }
                        [plans addObject:plan];
                    }
                }
            }
            
            if ([plans count]) {
                id<SPKQueryPlanner> planner = options[@"queryPlanner"];
                id<SPKTree,GTWQueryPlan> plan   = [plans lastObject];
                [plans removeLastObject];
                while ([plans count] > 0) {
                    id<SPKTree,GTWQueryPlan> p  = [plans lastObject];
                    [plans removeLastObject];
                    plan    = [planner joinPlanForPlans:p and:plan];
                }
                
                if ([otherTriples count]) {
                    for (id<SPKTree> tripleTree in otherTriples) {
                        id<SPKTree,GTWQueryPlan> triplePlan = [planner queryPlanForAlgebra:tripleTree usingDataset:dataset withModel:model options:options];
                        plan    = [planner joinPlanForPlans:plan and:triplePlan];
                    }
                }
                
                //            NSLog(@"Custom query plan: ------------------->\n%@", plan);
                return plan;
            }
            return nil;
        }
    }
    return nil;
}

@end
