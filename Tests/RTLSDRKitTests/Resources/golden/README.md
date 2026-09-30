# Golden traces

Every USB control transfer made by an unmodified `rtl_sdr` (Homebrew librtlsdr 2.0.2) on a real RTL2838UHIDIR /
R820T dongle, recorded with `Tools/trace-librtlsdr.c`. One file per session, named after the command that
produced it (`rtl_sdr -f <Hz> -s <rate> [-g <dB>] [-p <ppm>] -n 65536`). Format: see `TracingTransport`.

`W` lines are what the reference wrote; `R` lines are what the dongle answered. The tests replay the writes into a
register file and require this driver's session to leave every register in the same state.
