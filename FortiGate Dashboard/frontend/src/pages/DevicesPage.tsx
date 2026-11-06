import { Typography, Box } from '@mui/material';
import { DeviceTable } from '../components/DeviceTable';

export function DevicesPage() {
  return (
    <Box sx={{ display: 'flex', flexDirection: 'column', height: '100%', gap: 2 }}>
      <Typography variant="h4">Devices</Typography>
      <Box sx={{ flexGrow: 1, display: 'flex', flexDirection: 'column' }}>
        <DeviceTable />
      </Box>
    </Box>
  );
}
