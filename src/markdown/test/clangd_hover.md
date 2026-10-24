### function `snprintf`  
provided by `<stdio.h>`  

---
→ `int`  
Parameters:  
- `char *restrict __s`
- `size_t __maxlen (aka unsigned long)`
- `const char *restrict __format`

Maximum chars of output to write in MAXLEN.  

---
```cpp
extern int snprintf(char *restrict __s, size_t __maxlen,
                    const char *restrict __format, ...)
```