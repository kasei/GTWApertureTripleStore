//
//  GTWApertureTripleStore.h
//  GTWApertureTripleStore
//
//  Created by Gregory Williams on 8/4/13.
//  Copyright (c) 2013 Gregory Todd Williams. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <GTWSWBase/GTWSWBase.h>
#import "FMDatabase.h"
#import <SPARQLKit/SPARQLKit.h>

@interface GTWApertureTripleStore : NSObject<GTWTripleStore,SPKQueryPlanner>

@property (retain) NSString* base;
@property (retain) FMDatabase* facesdb;
@property (retain) FMDatabase* librarydb;
@property (retain) FMDatabase* propdb;
@property (retain) NSMutableDictionary* faces;
@property (retain) NSMutableDictionary* people;
@property (retain) NSMutableDictionary* seenPeople;
@property id<GTWLogger> logger;

- (instancetype) initWithDictionary: (NSDictionary*) dictionary;
- (instancetype) initWithApertureBundlePath: (NSString*) path;
+ (NSString*) usage;

@end
