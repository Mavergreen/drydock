__attribute__((objc_root_class, availability(macos,introduced=10.0)))
@interface OldBase
+ (long)sharedName;
- (long)sharedName;
- (void)oldMethod;
- (long)scalar:(long)value;
@end

__attribute__((availability(macos,introduced=10.10)))
@interface LaterClass : OldBase
@property(readonly) long reading;
@property(getter=currentValue, setter=updateValue:) long value;
@end

@interface OldBase (Extras)
- (void)futureMethod __attribute__((availability(macos,introduced=10.12)));
- (void)deprecatedMethod __attribute__((availability(macos,introduced=10.1,deprecated=10.8)));
- (void)unavailableMethod __attribute__((unavailable));
@end

@protocol ProbeProtocol
@optional
- (void)maybe;
@end

@interface Adopter : OldBase <ProbeProtocol>
@end

@class ForwardOnly;
@protocol ForwardProtocol;

@protocol ParentProtocol
- (void)requiredMethod;
@end
@protocol ChildProtocol <ParentProtocol>
@property(readonly) long protocolReading;
@end
