# mtv-migration-stats

Shell script to extract completed migration timings from **Migration Toolkit for Virtualization (MTV)** and calculate per-GB metrics to support migration window planning.

## Requirements

- `oc` authenticated with cluster-admin or sufficient RBAC to read `migration` and `plan` resources in the MTV namespace
- `jq`
- `bc`

## Usage

```bash
chmod +x mtv-migration-stats.sh
./mtv-migration-stats.sh [-n NAMESPACE] [-o FORMAT]
```

| Flag | Default | Description |
|---|---|---|
| `-n` | `openshift-mtv` | MTV namespace |
| `-o` | `table` | Output format: `table`, `csv`, `json` |

## Output columns

| Column | Description |
|---|---|
| `TOTAL_MIN` | Total migration duration in minutes |
| `DISK_XFER_MIN` | Time spent on initial disk transfer from VMware |
| `CONV_MIN` | Time spent on image conversion (virt-v2v) |
| `XFER_V2V_MIN` | Time spent copying converted disks to PVC |
| `DISK_GB` | Total disk size in GB (from `DiskTransfer` progress) |
| `GB/MIN` | Transfer throughput |
| `MIN/GB` | Minutes per GB (used for window estimation) |

The `table` format also prints a summary with average, min, max, and ready-to-use estimates for 50, 100, 200, and 500 GB workloads.

## Examples

```bash
# Table output (default)
./mtv-migration-stats.sh

# Different namespace
./mtv-migration-stats.sh -n my-mtv-namespace

# Export to CSV
./mtv-migration-stats.sh -o csv > migrations.csv

# JSON for further processing
./mtv-migration-stats.sh -o json > migrations.json
```

## Notes

- Only migrations with `Succeeded=True` condition are processed.
- Disk size is read from the `DiskTransfer` pipeline step (`progress.total`, unit MB). This reflects the allocated disk size, not the actual data transferred.
- The `ImageConversion` step (virt-v2v) can dominate total time for large or complex VMs. Monitor it separately when planning windows.
- Estimates improve with more completed migrations. A minimum of 5–10 samples per storage/network profile is recommended before using averages for production planning.
