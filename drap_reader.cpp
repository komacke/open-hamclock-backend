#include <iostream>
#include <fstream>
#include <sstream>
#include <vector>
#include <ctime>
#include <cmath>
#include <cstring>

static const int DRAPDATA_NPTS   = 440;        // bins
static const int DRAPDATA_PERIOD = 24 * 3600;  // 24 hours window

struct DrapCache {
    float x[DRAPDATA_NPTS];  // hours ago
    float y[DRAPDATA_NPTS];  // max value seen
};

int main(int argc, char* argv[])
{
    if (argc != 2) {
        std::cerr << "Usage: " << argv[0] << " stats.txt\n";
        return 1;
    }

    std::ifstream infile(argv[1]);
    if (!infile.is_open()) {
        std::cerr << "Cannot open file\n";
        return 1;
    }

    DrapCache drap_cache;
    std::memset(&drap_cache, 0, sizeof(drap_cache));

    time_t t_now = std::time(nullptr);

    std::string line;
    int n_lines = 0;
    int accepted = 0;

    while (std::getline(infile, line)) {

        n_lines++;

        long utime;
        float min, max, mean;

        if (std::sscanf(line.c_str(), "%ld : %f %f %f",
                        &utime, &min, &max, &mean) != 4) {
            std::cerr << "Garbled: " << line << "\n";
            continue;
        }

        int age = t_now - utime;

        int xi = DRAPDATA_NPTS *
                 (DRAPDATA_PERIOD - age) /
                 DRAPDATA_PERIOD;

        if (xi < 0 || xi >= DRAPDATA_NPTS)
            continue;

        drap_cache.x[xi] = age / (-3600.0f);

        if (max > drap_cache.y[xi])
            drap_cache.y[xi] = max;

        accepted++;
    }

    infile.close();

    // Diagnostics
    int populated = 0;
    for (int i = 0; i < DRAPDATA_NPTS; i++)
        if (drap_cache.y[i] > 0)
            populated++;

    std::cout << "Lines read:      " << n_lines << "\n";
    std::cout << "Lines accepted:  " << accepted << "\n";
    std::cout << "Bins populated:  " << populated
              << " / " << DRAPDATA_NPTS << "\n";

    if (populated < DRAPDATA_NPTS / 2)
        std::cout << "Data likely too sparse\n";
    else
        std::cout << "Data density acceptable\n";

    return 0;
}
