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

@interface GTWApertureTripleStore : NSObject<GTWTripleStore>

@property (retain) NSString* base;
@property (retain) FMDatabase* facesdb;
@property (retain) FMDatabase* librarydb;
@property (retain) NSMutableDictionary* faces;
@property (retain) NSMutableDictionary* people;
@property (retain) NSMutableDictionary* seenPeople;

- (instancetype) initWithDictionary: (NSDictionary*) dictionary;
- (instancetype) initWithApertureBundlePath: (NSString*) path;
+ (NSString*) usage;

@end
