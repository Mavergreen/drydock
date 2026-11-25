// instantiate NIB: hosts the first top-level window's content view in a 668-wide window, lays it out, prints
//   conflicts=, label_height= and line_height= for the wrapping label.
// instantiate --tree NIB: prints each top-level object, and for a window every view, frame, text and cell.
#import <Cocoa/Cocoa.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static NSArray *load(const char *path) {
  NSString *file = [NSString stringWithUTF8String:path];
  BOOL dir = NO;
  if ([[NSFileManager defaultManager] fileExistsAtPath:file isDirectory:&dir] && dir)
    file = [file stringByAppendingPathComponent:@"keyedobjects.nib"];
  NSData *data = [NSData dataWithContentsOfFile:file];
  NSNib *nib = data == nil ? nil : [[NSNib alloc] initWithNibData:data bundle:nil];
  NSArray *top = nil;
  if (nib == nil || ![nib instantiateWithOwner:[NSObject new] topLevelObjects:&top]) return nil;
  return top;
}

static NSWindow *firstWindow(NSArray *top) {
  for (id o in top)
    if ([o isKindOfClass:[NSWindow class]]) return o;
  return nil;
}

static NSTextField *wrappingLabel(NSView *v) {
  if ([v isKindOfClass:[NSTextField class]] && [[(NSTextField *)v cell] wraps]) return (NSTextField *)v;
  for (NSView *s in [v subviews]) {
    NSTextField *t = wrappingLabel(s);
    if (t != nil) return t;
  }
  return nil;
}

static void describeCell(NSMutableString *out, NSCell *c) {
  if (c == nil) return;
  [out appendFormat:@" cell=%@ title=\"%@\" state=%ld wraps=%d", NSStringFromClass([c class]), [c title], (long)[c state],
                    [c wraps]];
  if ([c isKindOfClass:[NSButtonCell class]]) [out appendFormat:@" bezel=%ld", (long)[(NSButtonCell *)c bezelStyle]];
}

static void describeView(NSMutableString *out, NSView *v, int depth) {
  [out appendFormat:@"%*s%@ frame=%@ mask=%lu", depth * 2, "", NSStringFromClass([v class]), NSStringFromRect([v frame]),
                    (unsigned long)[v autoresizingMask]];
  if ([v isKindOfClass:[NSControl class]]) describeCell(out, [(NSControl *)v cell]);
  if ([v isKindOfClass:[NSBox class]]) [out appendFormat:@" title=\"%@\"", [(NSBox *)v title]];
  [out appendString:@"\n"];
  for (NSView *s in [v subviews]) describeView(out, s, depth + 1);
}

static int tree(const char *path) {
  NSArray *top = load(path);
  if (top == nil) return 1;
  NSMutableArray *blocks = [NSMutableArray array];
  for (id o in top) {
    NSMutableString *b = [NSMutableString stringWithFormat:@"%@", NSStringFromClass([o class])];
    if ([o isKindOfClass:[NSWindow class]]) {
      NSWindow *w = o;
      [b appendFormat:@" title=\"%@\" frame=%@ style=%lu\n", [w title], NSStringFromRect([w frame]),
                      (unsigned long)[w styleMask]];
      describeView(b, [w contentView], 1);
    } else if ([o isKindOfClass:[NSView class]]) {
      [b appendString:@"\n"];
      describeView(b, o, 1);
    } else {
      [b appendString:@"\n"];
    }
    [blocks addObject:b];
  }
  for (NSString *b in [blocks sortedArrayUsingSelector:@selector(compare:)]) printf("%s", [b UTF8String]);
  return 0;
}

static int layout(const char *path) {
  FILE *captured = tmpfile();
  int saved = dup(2);
  if (captured == NULL || saved < 0) return 1;
  fflush(stderr);
  dup2(fileno(captured), 2);

  NSArray *top = load(path);
  NSWindow *from = firstWindow(top);
  NSView *content = [from contentView];
  NSTextField *label = wrappingLabel(content);
  int status = 1;
  CGFloat height = 0, line = 0;
  if (label != nil) {
    NSFont *font = [label font];
    line = [[NSLayoutManager new] defaultLineHeightForFont:font];
    NSMutableString *text = [NSMutableString stringWithString:@"DDFixtureLongText"];
    NSDictionary *attrs = @{NSFontAttributeName : font};
    while ([text boundingRectWithSize:NSMakeSize(668, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin
                           attributes:attrs].size.height < 3 * line)
      [text appendString:@" DDFixtureLongText"];
    [label setStringValue:text];

    [content removeFromSuperview];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 668, 400) styleMask:NSBorderlessWindowMask
                                                backing:NSBackingStoreBuffered defer:YES];
    [content setFrameSize:NSMakeSize(668, [content frame].size.height)];
    [[w contentView] addSubview:content];
    [[w contentView] layoutSubtreeIfNeeded];
    height = [label frame].size.height;
    status = 0;
  }

  fflush(stderr);
  dup2(saved, 2);
  close(saved);
  long conflicts = 0;
  char buf[4096];
  const char *needle = "Unable to simultaneously satisfy constraints";
  rewind(captured);
  while (fgets(buf, sizeof buf, captured) != NULL) {
    fputs(buf, stderr);
    for (const char *p = buf; (p = strstr(p, needle)) != NULL; p += strlen(needle)) conflicts++;
  }
  if (label == nil) {
    fprintf(stderr, "instantiate: %s: %s\n", path, top == nil ? "does not instantiate" : "no window with a wrapping label");
    return status;
  }
  printf("conflicts=%ld\nlabel_height=%g\nline_height=%g\n", conflicts, (double)height, (double)line);
  return status;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    if (argc == 3 && strcmp(argv[1], "--tree") == 0) return tree(argv[2]);
    if (argc == 2) return layout(argv[1]);
    fprintf(stderr, "usage: instantiate [--tree] NIB\n");
    return 2;
  }
}
