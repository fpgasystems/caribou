//---------------------------------------------------------------------------
//--  Copyright 2015 - 2017 Systems Group, ETH Zurich
//-- 
//--  This hardware module is free software: you can redistribute it and/or
//--  modify it under the terms of the GNU General Public License as published
//--  by the Free Software Foundation, either version 3 of the License, or
//--  (at your option) any later version.
//-- 
//--  This program is distributed in the hope that it will be useful,
//--  but WITHOUT ANY WARRANTY; without even the implied warranty of
//--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//--  GNU General Public License for more details.
//-- 
//--  You should have received a copy of the GNU General Public License
//--  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//---------------------------------------------------------------------------

#include "fregex.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdbool.h>

char special_characters[9] = {'.', '*', '+', '(',')','[',']','|', 0};
char range_characters[3] = {'[',']', 0};
char choice_characters[4] = {'(',')','|', 0};
char wildcard_characters[4] = {'.', '*', '+', 0};

typedef struct Token {
	char characters[MAX_CHARS];
	bool is_range;
	int size;
	int real_offs;
} Token ;

typedef struct State {
	int id;
	int out_edge[MAX_STATES];
	int out_cnt;
	int in_edge[MAX_STATES];
	int in_cnt;
	bool is_sticky;
	int tokens[MAX_CHARS];
	int token_cnt;
	bool is_accepting;
} State ;

bool in_set(char x, char* set) {
	int i;
	for (i=0; set[i]!=0; i++) {
		if (x==set[i]) return true;
	}

	return false;
}


void copy_state(State* dest, State* src) {
	dest->id = src->id;
	dest->out_cnt = src->out_cnt;
	dest->in_cnt = src->in_cnt;
	dest->is_sticky = src->is_sticky;
	dest->token_cnt = src->token_cnt;
	dest->is_accepting = src->is_accepting;

	memcpy(dest->in_edge, src->in_edge, sizeof(int)*MAX_STATES);
	memcpy(dest->out_edge, src->out_edge, sizeof(int)*MAX_STATES);
	memcpy(dest->tokens, src->tokens, sizeof(int)*MAX_CHARS);

}


int parse_sequence(const char* regex_string, int pos, State* states, int* s_loc, Token* tokens, int* t_loc) {	
	int cur_pos = pos;
	char temp[128];
	int cnt = 0;

	while (!in_set(regex_string[cur_pos], special_characters) && regex_string[cur_pos]!=0) {
		temp[cnt] = regex_string[cur_pos];
		cur_pos++;
		cnt++;		
	}

	if (DEBUG) printf("->sequence\n");

	if (cnt>0) {
		(*t_loc)++;
		memcpy(tokens[(*t_loc)].characters, temp, cnt);
		tokens[(*t_loc)].size = cnt;
		tokens[(*t_loc)].is_range = false;

		(*s_loc)++;
		states[(*s_loc)].id = *s_loc;
		states[(*s_loc)].is_sticky = false;
		states[(*s_loc)].token_cnt = 1;
		states[(*s_loc)].tokens[0] = (*t_loc);
		states[(*s_loc)].in_cnt = 0;
		states[(*s_loc)].out_cnt = 0;
		states[(*s_loc)].is_accepting = false;

		if (regex_string[cur_pos]==0) {
			states[(*s_loc)].is_accepting = true;			
		}

	}

	return cur_pos;
}

int parse_range(const char* regex_string, int pos, State* states, int* s_loc, Token* tokens, int* t_loc) {
	int cur_pos = pos;
	char temp[128];
	int cnt = 0;	
	bool is_range = false;

	while (regex_string[cur_pos]!=']' && regex_string[cur_pos]!=0) {

		if (regex_string[cur_pos] == '[') {
			//--
		} else if (regex_string[cur_pos] == '-') {
			is_range = true;
		} else {
			temp[cnt] = regex_string[cur_pos];
			cnt++;		
		}

		cur_pos++;
	}
	if (regex_string[cur_pos] == ']') cur_pos++;

	if (DEBUG) printf("->range\n");
	if (cnt==2 && is_range==true) {

		(*t_loc)++;
		memcpy(tokens[(*t_loc)].characters, temp, 2);
		tokens[(*t_loc)].size = 2;
		tokens[(*t_loc)].is_range = true;

		(*s_loc)++;
		states[(*s_loc)].id = *s_loc;
		states[(*s_loc)].is_sticky = false;
		states[(*s_loc)].token_cnt = 1;
		states[(*s_loc)].tokens[0] = (*t_loc);
		states[(*s_loc)].in_cnt = 0;
		states[(*s_loc)].out_cnt = 0;
		states[(*s_loc)].is_accepting = false;

		if (regex_string[cur_pos]==0) {
			states[(*s_loc)].is_accepting = true;			
		}

	} else if (cnt>0 && is_range==false) {
		int p;

		for (p=0; p<cnt; p++) {
			(*t_loc)++;
			tokens[(*t_loc)].characters[0] = temp[p];
			tokens[(*t_loc)].size = 1;
			tokens[(*t_loc)].is_range = false;
		}

		(*s_loc)++;
		states[(*s_loc)].id = *s_loc;
		states[(*s_loc)].is_sticky = false;
		states[(*s_loc)].token_cnt = cnt;
		for (p=0; p<cnt; p++) {
			states[(*s_loc)].tokens[p] = (*t_loc)-p;
		}
		states[(*s_loc)].in_cnt = 0;
		states[(*s_loc)].out_cnt = 0;
		states[(*s_loc)].is_accepting = false;

		if (regex_string[cur_pos]==0) {
			states[(*s_loc)].is_accepting = true;			
		}
	}

	return cur_pos;
}

int parse_choice(const char* regex_string, int pos, State* states, int* s_loc, Token* tokens, int* t_loc) {
	int cur_pos = pos;
	char temp[128];
	int cnt = 0;	
	bool is_range = false;
	int patcnt = 0;

	while (regex_string[cur_pos]!=')' && regex_string[cur_pos]!=0) {

		if (regex_string[cur_pos] == '(') {
			//--
		} else if (regex_string[cur_pos] == '|') {
			
			patcnt++;
			(*t_loc)++;
			memcpy(tokens[(*t_loc)].characters, temp, cnt);
			tokens[(*t_loc)].size = cnt;
			tokens[(*t_loc)].is_range = false;
			cnt = 0;


		} else {
			temp[cnt] = regex_string[cur_pos];
			cnt++;		
		}

		cur_pos++;
	}
	if (regex_string[cur_pos] == ')') cur_pos++;

	if (cnt>0) {
		patcnt++;	
		(*t_loc)++;
		memcpy(tokens[(*t_loc)].characters, temp, cnt);
		tokens[(*t_loc)].size = cnt;
		tokens[(*t_loc)].is_range = false;
		cnt = 0;
	}

	if (DEBUG) printf("->choice\n");
	if (patcnt>0) {
		int p;

		(*s_loc)++;
		states[(*s_loc)].id = *s_loc;
		states[(*s_loc)].is_sticky = false;
		states[(*s_loc)].token_cnt = patcnt;
		for (p=0; p<patcnt; p++) {
			states[(*s_loc)].tokens[p] = (*t_loc)-p;
		}
		states[(*s_loc)].in_cnt = 0;
		states[(*s_loc)].out_cnt = 0;
		states[(*s_loc)].is_accepting = false;

		if (regex_string[cur_pos]==0) {
			states[(*s_loc)].is_accepting = true;			
		}
	}

	return cur_pos;
}

int parse_wildcard(const char* regex_string, int pos, State* states, int* s_loc, Token* tokens, int* t_loc) {
	int cur_pos = pos;
	
	if (DEBUG) printf("->wildcard\n");

	if (regex_string[cur_pos]=='.' && regex_string[cur_pos+1]=='*') {
		cur_pos+=2;

		//(*s_loc)++;
		//states[(*s_loc)].id = *s_loc;
		states[(*s_loc)].is_sticky = true;
		//states[(*s_loc)].token_cnt = 0;
		//states[(*s_loc)].in_cnt = 1;
		//states[(*s_loc)].out_cnt = 0;
		//states[(*s_loc)].in_edge[0] = (*s_loc)-1;

		//states[(*s_loc)-1].out_edge[states[(*s_loc)-1].out_cnt]=(*s_loc);
		//states[(*s_loc)-1].out_cnt++;

	} else if (regex_string[cur_pos]=='+') {
		states[(*s_loc)].out_edge[states[(*s_loc)].out_cnt] = *s_loc;
		states[(*s_loc)].in_edge[states[(*s_loc)].in_cnt] = *s_loc;
		states[(*s_loc)].out_cnt++;
		states[(*s_loc)].in_cnt++;
		cur_pos++;
	}

	return cur_pos;
}

void fix_inequal_tokens(State* states, int* s_loc, Token* tokens) {
	int i,j;
	if (DEBUG) printf("->equalize\n");

	for (i=0; i<(*s_loc)+1; i++) {
		for (j=1; j<states[i].token_cnt; j++) {
			if (tokens[states[i].tokens[j]].size!=tokens[states[i].tokens[j-1]].size) {

				(*s_loc)++;
				states[(*s_loc)].id = *s_loc;
				states[(*s_loc)].in_cnt = states[i].in_cnt;
				states[(*s_loc)].out_cnt = states[i].out_cnt;
				states[(*s_loc)].is_accepting = false;

				memcpy(states[(*s_loc)].in_edge, states[i].in_edge, sizeof(int)*states[i].in_cnt);
				memcpy(states[(*s_loc)].out_edge, states[i].out_edge, sizeof(int)*states[i].out_cnt);
				states[*(s_loc)].token_cnt = 1;
				states[*(s_loc)].tokens[0] = states[i].tokens[j];

				int r;

				for (r=0; r<states[(*s_loc)].out_cnt; r++) {
					int other = states[(*s_loc)].out_edge[r];
					int other_incnt = states[other].in_cnt;
					states[other].in_edge[other_incnt] = (*s_loc);
					states[other].in_cnt++;
				}

				for (r=0; r<states[(*s_loc)].in_cnt; r++) {
					int other = states[(*s_loc)].in_edge[r];
					int other_outcnt = states[other].out_cnt;
					states[other].out_edge[other_outcnt] = (*s_loc);
					states[other].out_cnt++;
				}
				
				for (r=j; r<states[i].token_cnt-1; r++) {
					states[i].tokens[r] = states[i].tokens[r+1];
				}
				states[i].token_cnt--;

			}
		}
	}
}

int rename_accepting_state(State* states, int s_loc, int max_states) {

	int i; 
	for (i=0; i<=s_loc; i++) {
		if (states[i].is_accepting) {

			//move state on the desired position to the end
			

			int s,e;
			for (s=0; s<=s_loc; s++) {
				if (s!=i) {
					for (e=0; e<states[s].in_cnt; e++) {
						if (states[s].in_edge[e]==max_states-1) {
							states[s].in_edge[e] = max_states;
						}
					}

					for (e=0; e<states[s].out_cnt; e++) {
						if (states[s].out_edge[e]==max_states-1) {
							states[s].out_edge[e] = max_states;
						}
					}
				}
			}
		
			for (s=0; s<=s_loc; s++) {
				if (s!=i) {
					for (e=0; e<states[s].in_cnt; e++) {
						if (states[s].in_edge[e]==i) {
							states[s].in_edge[e] = max_states-1;
						}
					}

					for (e=0; e<states[s].out_cnt; e++) {
						if (states[s].out_edge[e]==i) {
							states[s].out_edge[e] = max_states-1;
						}
					}
				}
			}


			for (s=0; s<=s_loc; s++) {
				if (s!=i) {
					for (e=0; e<states[s].in_cnt; e++) {
						if (states[s].in_edge[e]==max_states) {
							states[s].in_edge[e] = i;
						}
					}

					for (e=0; e<states[s].out_cnt; e++) {
						if (states[s].out_edge[e]==max_states) {
							states[s].out_edge[e] = i;
						}
					}
				}
			}

			copy_state(&states[max_states], &states[max_states-1]);
			copy_state(&states[max_states-1], &states[i]);
			copy_state(&states[i], &states[max_states]);

			states[i].id = i;
			states[max_states-1].id = max_states-1;

			return max_states-1;

		}
	}

	return 0;
}


int fregex_get_config(const char* regex_string, int char_cnt, int state_cnt, unsigned char* config_bytes, int* config_len) {

	State states[state_cnt+1];
	Token tokens[char_cnt+1];

	int x;
	for (x=0; x<=state_cnt; x++) {
		states[x].id = -1;
		states[x].in_cnt = 0;
		states[x].out_cnt = 0;
		states[x].token_cnt = 0;
		states[x].is_sticky = 0;
		states[x].is_accepting = 0;
	}

	int parsed_to = 0;
	int last_to = 0;

	int s_loc = -1;
	int t_loc = -1;	

	int last_sl;
	int last_tl;
	int last_type = 1;
	int cur_type = 0;

	while (regex_string[parsed_to]!=0) {

		if (DEBUG) printf("parsed_to %d\n", parsed_to);

		last_sl = s_loc;
		last_tl = t_loc;
		last_type = cur_type;
		last_to = parsed_to;

		if (!in_set(regex_string[parsed_to], special_characters)) {
			parsed_to = parse_sequence(regex_string, parsed_to, states, &s_loc, tokens, &t_loc);			
			cur_type = 1;
		} else if (in_set(regex_string[parsed_to], range_characters)) {
			parsed_to = parse_range(regex_string, parsed_to, states, &s_loc, tokens, &t_loc);			
			cur_type = 2;
		} else if (in_set(regex_string[parsed_to], choice_characters)) {
			parsed_to = parse_choice(regex_string, parsed_to, states, &s_loc, tokens, &t_loc);			
			cur_type = 3;
		} else if (in_set(regex_string[parsed_to], wildcard_characters)) {
		  parsed_to = parse_wildcard(regex_string, parsed_to, states, &s_loc, tokens, &t_loc);
			if (parsed_to==last_to+1) {
				cur_type = last_type;
			} else {
				cur_type = 4;
			}
		}

		if ((cur_type==1 || cur_type==2 || cur_type==3) && last_sl>=0) {
			//if (last_type==1 || last_type==2 || last_type==3) {				
				int csl = last_sl+1;

				for (csl=last_sl+1; csl<=s_loc; csl++) {

					states[csl].in_edge[states[csl].in_cnt] = last_sl;
					states[csl].in_cnt++;

					states[last_sl].out_edge[states[last_sl].out_cnt] = csl;
					states[last_sl].out_cnt++;			
				}

			//}

			/*if (last_type==4) {

				int csl = last_sl+1;

				for (csl=last_sl+1; csl<=s_loc; csl++) {

					states[csl].in_edge[states[csl].in_cnt] = last_sl;
					states[csl].in_cnt++;

					states[last_sl].in_edge[states[last_sl].out_cnt] = csl;
					states[last_sl].out_cnt++;			

					states[csl].in_edge[states[csl].in_cnt] = last_sl-1;
					states[csl].in_cnt++;

					states[last_sl-1].in_edge[states[last_sl-1].out_cnt] = csl;
					states[last_sl-1].out_cnt++;		
				}
			}*/
		}

	}

	fix_inequal_tokens(states, &s_loc, tokens);	

	s_loc = rename_accepting_state(states, s_loc, state_cnt);


	if (DEBUG) {

		printf("\n");
		// printout:
		int t,i;
		for (t=0; t<=t_loc; t++) {
			printf("TOKEN %d: range %d, len %d, chars: ", t, tokens[t].is_range, tokens[t].size);
			for (i=0; i<tokens[t].size; i++) {
				printf("%c ", tokens[t].characters[i]);
			}
			printf("\n");	
		}

		printf("\n");

		int s;
		for (s=0; s<=s_loc; s++) {
			printf("STATE %d: sticky %d, slen %d, tokens: ", states[s].id, states[s].is_sticky, states[s].token_cnt > 0 ? tokens[states[s].tokens[0]].size : 0);

			for (i=0; i<states[s].token_cnt; i++) {
				printf("%d ",states[s].tokens[i]);
			}

			printf("\n");
		}

		printf("\n");

		for (s=0; s<=s_loc; s++) {
			printf("S%d --> ", states[s].id);

			for (i=0; i<states[s].out_cnt; i++) {
				printf("S%d ", states[states[s].out_edge[i]].id);
			}


			printf("\n");
		}

		printf("\n");

		for (s=0; s<=s_loc; s++) {
			printf("S%d <-- ", states[s].id);

			for (i=0; i<states[s].in_cnt; i++) {
				printf("S%d ", states[states[s].in_edge[i]].id);
			}


			printf("\n");
		}
	} // DEBUG


	char ochars[char_cnt];
	bool oseq[char_cnt];
	bool orange[char_cnt/2];

	bool oactivates[state_cnt][char_cnt];
	bool otrans[state_cnt][state_cnt];
	bool osticky[state_cnt];
	unsigned char oslen[state_cnt];

	int bytes_used = 0;


	int t, i;
	int cpos = 0;

	for (i=0; i<char_cnt; i++) {
		ochars[i] = 0;
		oseq[i] = false;
		orange[i/2] = false;
	}


	for (t=0; t<=t_loc; t++) {
		if (tokens[t].is_range && cpos%2!=0) {
			cpos++;
		}
		for (i=0; i<tokens[t].size; i++) {
			ochars[cpos] = tokens[t].characters[i];
			oseq[cpos] = (i>0 && !tokens[t].is_range) ? true : false;
			orange[cpos/2] =  (i>0 && tokens[t].is_range) ? true : false;			
			cpos++;

			if (cpos > char_cnt) {
				return 0; 
			}
		}
		tokens[t].real_offs = cpos-1;
		if (DEBUG) printf("Updated pos of Token %d is at %d\n", t, cpos-tokens[t].size);
	}

	if (DEBUG) printf("\n");

	int s;

	for (s=0; s<state_cnt; s++) {
		for (i=0; i<char_cnt; i++) {
			oactivates[s][i]=false;
		}
		for (i=0; i<state_cnt; i++) {
			otrans[s][i] = false;			
		}
		oslen[s] = 0;
		osticky[s] = 0;
	}

	for (s=0; s<=s_loc; s++) {
		osticky[s] = states[s].is_sticky;
		oslen[s] = states[s].token_cnt > 0 ? tokens[states[s].tokens[0]].size : 0;

		for (i=0; i<states[s].token_cnt; i++) {
			oactivates[s][tokens[states[s].tokens[i]].real_offs] = true;
		}

		for (i=0; i<states[s].in_cnt; i++) {
			otrans[s][states[s].in_edge[i]] = true;
		}		
	}

	//chars
	for (i=0; i<char_cnt; i++) {
		if (DEBUG) printf("%d ", ochars[i]);
		config_bytes[bytes_used] = ochars[i]; 
		bytes_used ++;

	}

	if (DEBUG) printf("\t");


	//ranges
	unsigned char aux = 0;
	int bitpos = 0;
	for (i=0; i<char_cnt/2; i++) {
		if (orange[i]==true) aux += (unsigned char)1 << i%8;		
		if (bitpos%8==7) {
			if (DEBUG) printf("%2x ", aux);
			config_bytes[bytes_used] = aux;
			bytes_used ++;
			aux = 0;
		} else {
			//aux = aux << 1;
		}		
		bitpos++;
	}

	if (DEBUG) printf("\t");

	//sequence conds
	for (i=0; i<char_cnt; i++) {
		if (oseq[i]==true) aux += (unsigned char)1 << i%8;

		if (bitpos%8==7) {
			if (DEBUG) printf("%2x ", aux);
			config_bytes[bytes_used] = aux;
			bytes_used ++;
			aux = 0;
		} else {
			//aux = aux << 1;
		}		
		bitpos++;
	}

	if (DEBUG) printf("\t");

	//triggers
	for (s=0; s<state_cnt; s++) {
		for (i=0; i<char_cnt; i++) {
			if (oactivates[s][i]==true) aux += (unsigned char)1 << i%8;

			if (bitpos%8==7) {
				if (DEBUG) printf("%2x ", aux);
				config_bytes[bytes_used] = aux;
				bytes_used ++;
				aux = 0;
			} else {
				//aux = aux << 1;
			}		
			bitpos++;
		}
	}

	if (DEBUG) printf("\t");

	//trasnitions into
	for (s=0; s<state_cnt; s++) {
		for (i=0; i<state_cnt; i++) {
			if (otrans[s][i]==true) aux += (unsigned char)1 << bitpos%8;

			if (bitpos%8==7) {
				if (DEBUG) printf("%2x ", aux);
				config_bytes[bytes_used] = aux;
				bytes_used ++;
				aux = 0;
			} else {
				//aux = aux << 1;
			}	
			bitpos++;	
		}
	}

	if (bitpos%8!=0) {
		if (DEBUG) printf("%2x ", aux);
		config_bytes[bytes_used] = aux;
		bytes_used ++;
		aux = 0;
	} else {
		//aux = aux << 1;
	}	
	

	if (DEBUG) printf("\t");

	//state lengths
	aux = 0;
	for (i=0; i<state_cnt; i++) {
		if (oslen[i]==0) {
			aux += 0 << ((i%2)*4);
		} else {
			aux += (oslen[i]-1) << ((i%2)*4);
		}


		if (i%2==1) {
			if (DEBUG) printf("%2x ", aux);
			config_bytes[bytes_used] = aux;
			bytes_used ++;
			aux = 0;
		} else {
			//aux = aux << 4;
		}		
	}

	if (DEBUG) printf("\t");

	bitpos = 0;
	//sticky
	for (i=0; i<state_cnt; i++) {
		if (osticky[i]==true) aux += (unsigned char)1 << i%8;

		if (bitpos%8==7) {
			if (DEBUG) printf("%2x ", aux);
			config_bytes[bytes_used] = aux;
			bytes_used ++;
			aux = 0;
		} else {
			//aux = aux << 1;
		}		
		bitpos ++;
	}
	if (bitpos%8!=0) {
		if (DEBUG) printf("%2x ", aux);
		config_bytes[bytes_used] = aux;
		bytes_used ++;
		aux = 0;
	} else {
		//aux = aux << 1;
	}

	if (SUPPORTS_CASE_INSENSITIVE==true) {

		for (i=0; i<char_cnt; i++) {
			if (ochars[i]>='A' && ochars[i]<='Z' && orange[i/2]==false) aux += (unsigned char)1 << i%8;

			if (i%8==7) {
				if (DEBUG) printf("%2x ", aux);
				config_bytes[bytes_used] = aux;
				bytes_used ++;
				aux = 0;
			}
		}
	}


	*(config_len) = bytes_used;

	return bytes_used;

}

int main(int argc, char** argv) {

	const int HW_STATES = 4;
	const int HW_CHARS = 16;

	if (argc!=2) {
		printf("Number of states: %d, Number of chars: %d\nUsage: <regex>", HW_STATES, HW_CHARS);
		return 0;
	}



	int config_len = 0;

	unsigned char config_bytes[256]; 
	int x;
	for (x=0; x<256; x++) {
		config_bytes[x] = 0;
	}


	fregex_get_config(argv[1], HW_CHARS, HW_STATES, config_bytes, &config_len);
		
	for (x=0; x<config_len; x++) {
	  printf("%d ", config_bytes[x]);
	}	
	
	if (DEBUG) printf("Config length %d\n", config_len*8);
}
