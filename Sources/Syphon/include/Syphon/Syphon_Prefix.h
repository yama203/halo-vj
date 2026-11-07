#if SYPHON_DEBUG_NO_DRAWING
	#define DEBUG 1
#endif

#ifdef __OBJC__
    #import <Cocoa/Cocoa.h>

	// logging only enabled if debug is on. 
	#ifdef SYPHON_DEBUG  // Halo VJ：SwiftPM のデバッグビルドは DEBUG が付くので、Syphon のログは SYPHON_DEBUG のときだけ
		#define SYPHONLOG(format, ...)  NSLog(@"SYPHON DEBUG: %@: %@", NSStringFromClass([self class]), [NSString stringWithFormat:format, ##__VA_ARGS__]);
	#else
		#define SYPHONLOG(format, ...) 
	#endif 
#endif
