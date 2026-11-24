#ifndef JANSSON_CONFIG_H
#define JANSSON_CONFIG_H

#define JSON_INLINE inline
#define JSON_INTEGER_IS_LONG_LONG 1
#define JSON_HAVE_ATOMIC_BUILTINS 1
#define JSON_HAVE_SYNC_BUILTINS 1
/* 10.9's NSJSONSerialization, the front end this parser replaced, refused 514 levels; so does drydock-objc. */
#define JSON_PARSER_MAX_DEPTH 513

#endif
