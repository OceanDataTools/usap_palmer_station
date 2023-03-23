# usap_palmer_station
Data and code specific to Palmer Station

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
