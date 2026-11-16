import { Chip, Stack, Tooltip, Typography } from '@mui/material';

export interface ReachabilityState {
  ipAddress: string | null;
  icmpReachable: boolean | null;
  sshPortOpen: boolean | null;
  httpsPortOpen: boolean | null;
  port9443Open: boolean | null;
  reachabilityCheckedAt: string | null;
}

const REACHABILITY_PROBES: { label: string; key: 'icmpReachable' | 'sshPortOpen' | 'httpsPortOpen' | 'port9443Open' }[] = [
  { label: 'ICMP', key: 'icmpReachable' },
  { label: '22', key: 'sshPortOpen' },
  { label: '443', key: 'httpsPortOpen' },
  { label: '9443', key: 'port9443Open' }
];

export function ReachabilityChips({ device }: { device: ReachabilityState }) {
  if (!device.ipAddress) {
    return <>—</>;
  }
  if (device.reachabilityCheckedAt === null) {
    return <Typography variant="caption" color="text.secondary">Not checked</Typography>;
  }
  const checkedAt = new Date(device.reachabilityCheckedAt).toLocaleString();
  return (
    <Stack direction="row" spacing={0.5}>
      {REACHABILITY_PROBES.map(({ label, key }) => {
        const responding = device[key] === true;
        return (
          <Tooltip
            key={key}
            title={`${label === 'ICMP' ? 'ICMP ping' : `TCP port ${label}`}: ${responding ? 'responding' : 'not responding'} (checked ${checkedAt})`}
          >
            <Chip size="small" label={label} color={responding ? 'success' : 'error'} variant={responding ? 'filled' : 'outlined'} />
          </Tooltip>
        );
      })}
    </Stack>
  );
}
