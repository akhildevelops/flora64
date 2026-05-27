#!/usr/bin/env python3
"""Generate a ~100MB GeoJSON FeatureCollection file with many Point features."""
import sys
import os
from pathlib import Path
target_bytes =  1024 * 1024 * 1024  # 1GB
n_files = 5
output_path_folder = sys.argv[1] if len(sys.argv)>1 else "ideapad/100mb/"
Path(output_path_folder).mkdir(parents=True,exist_ok=True)
for i in range(n_files):
    output_path=f"{output_path_folder}_{i}.geojson"
    with open(output_path, 'w') as f:
        f.write('{"type":"FeatureCollection","features":[')

        count = 0
        while True:
            lon = 78.0 + (count % 360) * 0.01
            lat = 17.0 + ((count // 360) % 180) * 0.01
            name = f"City_{count}"
            pop = 1000000 + (count % 9000000)
            
            if count > 0:
                f.write(',')
            
            f.write(f'{{"type":"Feature","properties":{{"name":"{name}","population":{pop}}},"geometry":{{"type":"Point","coordinates":[{lon:.4f},{lat:.4f}]}}}}')
            count += 1
            
            if count % 50000 == 0:
                cur_size = os.path.getsize(output_path)
                if cur_size >= target_bytes:
                    break
        
        f.write(']}')
        
        final_size = os.path.getsize(output_path)
        print(f"Generated {output_path}")
        print(f"  Features: {count}")
        print(f"  Size: {final_size:,} bytes ({final_size / 1024 / 1024:.1f} MB)")
