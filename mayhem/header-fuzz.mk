# Extra make rules (passed with `make -f Makefile -f mayhem/header-fuzz.mk`) linking mayhem/header-fuzz.c
# the way upstream's Makefile links fuzz/body.c.
FUZZ_HEADER = fuzz/header-fuzz$(EXEEXT)

fuzz/header.o: $(SRCDIR)/mayhem/header-fuzz.c
	$(CC) $(CFLAGS) -c -o $@ $<

$(FUZZ_HEADER): fuzz/header.o $(NEOMUTTOBJS) $(LIBCOMMANDS) $(LIBHOOKS) $(MUTTLIBS) $(NEOMUTTLIBS)
	$(CXX) $(CXXFLAGS) -o $@ fuzz/header.o $(NEOMUTTOBJS) $(LIBCOMMANDS) $(LIBHOOKS) $(MUTTLIBS) $(LIBCOMMANDS) $(LIBPARSE) $(LIBCONFIG) $(NEOMUTTLIBS) $(LDFLAGS) $(LIBS) $(LIB_FUZZING_ENGINE)
