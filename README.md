# open-hamclock-backend
Open Source HamClock Backend Replacement. This is a community project and no relation to the creator of HamClock Elwood Downey, WB0OEW, ecdowney@clearskyinstitute.com SK

# License
MIT - this is free. Not for commercial use

# Project Completion Status
- [x] Bz.txt generator
- [ ] aurora.txt generator
- [ ] VOACAP map generator
- [x] HamWeekly.com RSS feed generator
- [x] AR Newsline RSS feed generator
- [x] zlib decompress utilty script
- [x] Generic backend to keep HamClocks alive beyond June 2026
- [ ] Complete end-to-end working backend

# Vision
The goal is to make this as a drop-in replacement for the HamClock backend by replicating the same client/server responses with Perl CGI scripting and static files. We don't have access to the backend server source code so this is completely created by looking at the interfaces. To allow existing HamClock's running on Arduino to continue to work, we will setup a local DNS sinkhole to redirect to your local backend running at your home or office.

# Compile Backend

1. Use WSL2 and Ubuntu 22 LTS
2. Clone repository
3. go build
4. run hamclock-backend

# Using

1. Start hamclock application with hamclock -b ip:port (it can be localhost)
