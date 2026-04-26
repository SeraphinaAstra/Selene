content = open('Makefile').read()
content = content.replace(
    '\t$(CC) $(CFLAGS) -c -o $@ $\n',
    '\t$(CC) $(CFLAGS) -c -o $@ $<\n'
)
open('Makefile', 'w').write(content)
