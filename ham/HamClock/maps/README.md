# Generating Base Maps

sudo apt-get install gmt
gmt coast -R-180/180/-90/90 -JQ0/15c -W1p,white -N1/0.75p,white -A10000 -B+gblack -png world

sudo apt install gmt-gshhg gmt-dcw

chmod +x build_hamclock_base_maps.sh

./build_hamclock_base_maps.sh
