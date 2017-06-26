#ifndef F_REGEX
#define F_REGEX

#define MAX_CHARS 128
#define MAX_STATES 32

	#ifndef DEBUG
	#define DEBUG false
	#endif

#define bool short
#define true 1
#define false 0

#define SUPPORTS_CASE_INSENSITIVE false

int fregex_get_config(const char* regex_string, int char_cnt, int state_cnt, unsigned char* config_data, int* config_len);

#endif 
