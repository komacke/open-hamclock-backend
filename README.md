# 🛟 OHB — Open HamClock Backend
Open-source, self-hostable backend replacement for HamClock.

When the original backend went dark, the clocks didn’t have to.

OHB provides faithful replacements for the data feeds and map assets
that HamClock depends on — built by operators, for operators.

> This project is not affiliated with HamClock or its creator,
> Elwood Downey, WB0OEW.
> We extend our sincere condolences to the Downey family.

## ✨ What OHB Does

- Rebuilds HamClock dynamic text feeds (solar, geomag, DRAP, PSK, RBN, WSPR, Amateur Satellites, DxNews, Contests, etc)
- Generates map overlays (MUF-RT, DRAP, Aurora, Wx-mB, etc.)
- Produces zlib-compressed BMP assets in multiple resolutions
- Designed for Raspberry Pi, cloud, or on-prem deployment
- Fully open source and community maintained

## 🧭 Architecture
```
[ NOAA / KC2G / PSK / SWPC ]
              |
              v
        +-------------+
        |     OHB     |
        |-------------|
        | Python/Perl|
        | GMT/Maps   |
        | Cron Jobs  |
        +-------------+
              |
           HTTP/ZLIB
              |
         +----------+
         | lighttpd |
         +----------+
              |
         +----------+
         | HamClock |
         +----------+
```

## 💬 Join us on Discord
We are building a community-powered backend to keep HamClock running. \
Discord is where we can collaborate, troubleshoot, and exchange ideas — no RF license required 😎 \
https://discord.gg/wb8ATjVn6M

## 🚀 Quick Start 👉 [Quick Start Guide](QUICK_START.md)
## 📦 Installation 👉 [Detailed installation instructions](INSTALL.md)
## 📊 Project Completion Status

OHB targets ~40+ HamClock artifacts (feeds, maps, and endpoints).

Current highlights:

• All core dynamic maps implemented  
• All primary text feeds replicated  
• Integration-tested on live HamClock clients  
• Remaining work focused on VOACAP + RBN endpoints  

👉 Full artifact tracking and integration status:
[PROJECT_STATUS.md](PROJECT_STATUS.md) 
# 📚 Data Attribution 👉 [Attribution](ATTRIBUTION.md)
## 🤝 Contributing
