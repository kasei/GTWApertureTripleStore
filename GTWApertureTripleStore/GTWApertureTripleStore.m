//
//  GTWApertureTripleStore.m
//  GTWApertureTripleStore
//
//  Created by Gregory Williams on 8/4/13.
//  Copyright (c) 2013 Gregory Todd Williams. All rights reserved.
//

#define IRI(i) [[GTWIRI alloc] initWithIRI:i];
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
#import <GTWSWBase/GTWLiteral.h>
#import <GTWSWBase/GTWTriple.h>

@implementation GTWApertureTripleStore

+ (unsigned)interfaceVersion {
    return 0;
}

+ (NSString*) usage {
    return @"{ \"bundlepath\": <Path to Aperture Library.aplibrary file> }";
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
    
    {
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
    
    {
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
    
    {
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
                
                GTWIRI* subject     = [[GTWIRI alloc] initWithIRI:[NSString stringWithFormat:@"file://%@", photoPath]];
                GTWIRI* predicate   = IRI(@"http://www.w3.org/1999/02/22-rdf-syntax-ns#type");
                GTWIRI* object      = IRI(@"http://xmlns.com/foaf/0.1/Image");
                id<GTWTriple> t     = TRIPLE(subject, predicate, object);
                filter(t);
                
                for (id pid in set) {
                    NSDictionary* props = self.people[pid];
                    ABPerson* person = [self matchPersonFromProperties: props];
                    if (person) {
                        [self.seenPeople setObject:props forKey:person];
                        //                    NSString* name  = props[@"name"];
                        //                    NSLog(@"  - %@ (%@)", name, uri);
                        GTWIRI* predicate   = IRI(@"http://xmlns.com/foaf/0.1/depicts");
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
    
    
//    NSLog(@"People properties: %@", self.people);
    for (ABPerson* p in self.seenPeople) {
        id props    = [self.seenPeople objectForKey:p];
//        NSLog(@"props: %@", props);
        NSString* name  = props[@"name"];
//        NSString* email  = props[@"email"];
//        NSLog(@"person unique ID: %@", [p uniqueId]);
        GTWIRI* subject     = [self iriForPersonID:[p uniqueId]];
        GTWIRI* foafname    = IRI(@"http://xmlns.com/foaf/0.1/name");
        GTWIRI* foafmbox    = IRI(@"http://xmlns.com/foaf/0.1/mbox_sha1sum");
        GTWIRI* foafPerson  = IRI(@"http://xmlns.com/foaf/0.1/Person");
        GTWIRI* rdftype     = IRI(@"http://www.w3.org/1999/02/22-rdf-syntax-ns#type");
        filter(TRIPLE(subject, rdftype, foafPerson));
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


@end
