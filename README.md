# usap_palmer_station
Data and code specific to Palmer Station

This code should only be loaded *after* the `utils/install_openrvdas.sh` and
`utils/install_influxdb.sh` scripts have been run.

To install this code for use,
```
   sudo mkdir /opt/oceandatatools_local
   sudo chown rvdas /opt/oceandatatools_local
   sudo chgrp rvdas /opt/oceandatatools_local

   # Everything from here on should be done as user 'rvdas',
   # if you're not already doing so.
   su rvdas
   cd /opt/oceandatatools_local
   mkdir -p usap
   cd usap
   git clone https://github.com/OceanDataTools/usap_palmer_station.git palmer

   # Link into right place in openrvdas/local dir
   cd /opt/openrvdas/local
   ln -s /opt/oceandatatools_local/usap/palmer usap/palmer
```
The installation script will 

- Set up the directory where data will be written.
- Copy template files from the dist directory into loadable yaml files in the
  configs directory, and substitute the actual location(s)
  of the data directory and relevant serial port(s) into them. 
- Create a waterwall_logger.conf file for the supervisord to run and put it in the
  right place.
- Disable the default (and now unneeded) openrvdas.conf file for supervisord.
- Restart supervisord to get things running.
