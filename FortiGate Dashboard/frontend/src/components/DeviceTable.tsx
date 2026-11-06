import { useCallback, useMemo, useState } from 'react';
import {
  Box,
  Button,
  Chip,
  Link as MuiLink,
  MenuItem,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TablePagination,
  TableRow,
  TableSortLabel,
  TextField,
  Tooltip,
  Typography
} from '@mui/material';
import { useNavigate } from 'react-router-dom';
import { useQuery } from '../hooks/useQuery';
import { devicesApi } from '../api/endpoints';
import type { DeviceListItem } from '../types';
import { exportDevicesToExcel, subscriptionStatusColor } from '../utils/formatting';

const SUBSCRIPTION_STATUSES = ['', 'Healthy', 'Warning', 'Critical', 'Expired'];
const CLOUD_STATUSES = ['', 'Registered', 'Deregistered'];
const TRI_STATE_OPTIONS = [
  { value: '', label: 'All' },
  { value: 'true', label: 'Yes' },
  { value: 'false', label: 'No' }
];
type SortField = 'name' | 'serialNumber' | 'model' | 'firmwareVersion' | 'tunnelAlive' | 'ipAddress' | 'hostname' | 'cloudManagementStatus' | 'subscriptionStatus' | 'expiryDate' | 'criticalCveCount' | 'highestCvss' | 'latestPsirtUrl' | 'unableToEvaluateCount';
type SortDirection = 'asc' | 'desc';

const openAdminInterface = (ipAddress: string) => {
  // Try primary port first (8443), fallback to 8444
  const primaryUrl = `https://${ipAddress}:8443`;
  const fallbackUrl = `https://${ipAddress}:8444`;
  
  const newWindow = window.open(primaryUrl, '_blank', 'noopener,noreferrer');
  
  // If primary port fails after a delay, try fallback
  if (newWindow) {
    const timeout = setTimeout(() => {
      // Send a message to check if the window successfully loaded
      // If not, open the fallback URL in a new window
      try {
        if (newWindow.closed) {
          window.open(fallbackUrl, '_blank', 'noopener,noreferrer');
        }
      } catch {
        // Handle CORS restrictions
        window.open(fallbackUrl, '_blank', 'noopener,noreferrer');
      }
    }, 2000);
    
    // Clean up timeout if window loads successfully
    newWindow.addEventListener('load', () => clearTimeout(timeout));
  }
};

function parseOptionalBoolean(value: string): boolean | undefined {
  return value === '' ? undefined : value === 'true';
}

export function DeviceTable() {
  const navigate = useNavigate();
  const [search, setSearch] = useState('');
  const [subscriptionStatus, setSubscriptionStatus] = useState('');
  const [cloudManagementStatus, setCloudManagementStatus] = useState('');
  const [hasCriticalCves, setHasCriticalCves] = useState('');
  const [hasPsirt, setHasPsirt] = useState('');
  const [hasUnresolved, setHasUnresolved] = useState('');
  const [minimumCvss, setMinimumCvss] = useState('');
  const [tunnelAlive, setTunnelAlive] = useState('');
  const [page, setPage] = useState(0);
  const [pageSize, setPageSize] = useState(25);
  const [sortField, setSortField] = useState<SortField>('name');
  const [sortDirection, setSortDirection] = useState<SortDirection>('asc');

  const query = useMemo(
    () => ({
      search: search || undefined,
      subscriptionStatus: subscriptionStatus || undefined,
      cloudManagementStatus: cloudManagementStatus || undefined,
      hasCriticalCves: parseOptionalBoolean(hasCriticalCves),
      hasPsirt: parseOptionalBoolean(hasPsirt),
      hasUnresolved: parseOptionalBoolean(hasUnresolved),
      minimumCvss: minimumCvss === '' ? undefined : Number(minimumCvss),
      tunnelAlive: parseOptionalBoolean(tunnelAlive),
      sortBy: sortField,
      descending: sortDirection === 'desc',
      page: page + 1,
      pageSize
    }),
    [search, subscriptionStatus, cloudManagementStatus, hasCriticalCves, hasPsirt, hasUnresolved, minimumCvss, tunnelAlive, sortField, sortDirection, page, pageSize]
  );

  const { data, loading } = useQuery(() => devicesApi.list(query), [query]);

  const handleSort = (field: SortField) => {
    setPage(0);
    if (sortField === field) {
      setSortDirection((direction) => direction === 'asc' ? 'desc' : 'asc');
      return;
    }

    setSortField(field);
    setSortDirection('asc');
  };

  const sortableHeader = (field: SortField, label: string) => (
    <TableSortLabel active={sortField === field} direction={sortField === field ? sortDirection : 'asc'} onClick={() => handleSort(field)}>
      {label}
    </TableSortLabel>
  );

  const handleExportExcel = useCallback(() => {
    if (data) {
      exportDevicesToExcel(data.items);
    }
  }, [data]);

  return (
    <Box sx={{ display: 'flex', flexDirection: 'column', width: '100%', height: '100%' }}>
      <Stack direction={{ xs: 'column', sm: 'row' }} spacing={2} sx={{ mb: 2 }} alignItems="center">
        <TextField
          label="Search"
          size="small"
          value={search}
          onChange={(e) => {
            setPage(0);
            setSearch(e.target.value);
          }}
          sx={{ minWidth: 220 }}
        />
        <TextField
          select
          label="Subscription status"
          size="small"
          value={subscriptionStatus}
          onChange={(e) => {
            setPage(0);
            setSubscriptionStatus(e.target.value);
          }}
          sx={{ minWidth: 180 }}
        >
          {SUBSCRIPTION_STATUSES.map((s) => (
            <MenuItem key={s} value={s}>
              {s || 'All'}
            </MenuItem>
          ))}
        </TextField>
        <TextField
          select
          label="Critical CVEs"
          size="small"
          value={hasCriticalCves}
          onChange={(e) => { setPage(0); setHasCriticalCves(e.target.value); }}
          sx={{ minWidth: 145 }}
        >
          {TRI_STATE_OPTIONS.map((option) => <MenuItem key={option.value} value={option.value}>{option.label}</MenuItem>)}
        </TextField>
        <TextField
          label="Minimum CVSS"
          size="small"
          type="number"
          inputProps={{ min: 0, max: 10, step: 0.1 }}
          value={minimumCvss}
          onChange={(e) => { setPage(0); setMinimumCvss(e.target.value); }}
          sx={{ minWidth: 140 }}
        />
        <TextField
          select
          label="Has PSIRT"
          size="small"
          value={hasPsirt}
          onChange={(e) => { setPage(0); setHasPsirt(e.target.value); }}
          sx={{ minWidth: 130 }}
        >
          {TRI_STATE_OPTIONS.map((option) => <MenuItem key={option.value} value={option.value}>{option.label}</MenuItem>)}
        </TextField>
        <TextField
          select
          label="Has unresolved"
          size="small"
          value={hasUnresolved}
          onChange={(e) => { setPage(0); setHasUnresolved(e.target.value); }}
          sx={{ minWidth: 150 }}
        >
          {TRI_STATE_OPTIONS.map((option) => <MenuItem key={option.value} value={option.value}>{option.label}</MenuItem>)}
        </TextField>
        <TextField
          select
          label="Tunnel up"
          size="small"
          value={tunnelAlive}
          onChange={(e) => { setPage(0); setTunnelAlive(e.target.value); }}
          sx={{ minWidth: 130 }}
        >
          {TRI_STATE_OPTIONS.map((option) => <MenuItem key={option.value} value={option.value}>{option.label}</MenuItem>)}
        </TextField>
        <TextField
          select
          label="Inventory status"
          size="small"
          value={cloudManagementStatus}
          onChange={(e) => {
            setPage(0);
            setCloudManagementStatus(e.target.value);
          }}
          sx={{ minWidth: 180 }}
        >
          {CLOUD_STATUSES.map((s) => (
            <MenuItem key={s} value={s}>
              {s || 'All'}
            </MenuItem>
          ))}
        </TextField>
        <Box sx={{ flexGrow: 1 }} />
        <Button variant="outlined" component="a" href={devicesApi.exportCsvUrl()}>
          Export CSV
        </Button>
        <Button variant="outlined" onClick={handleExportExcel}>
          Export Excel
        </Button>
      </Stack>

      <Typography variant="body2" color="text.secondary" sx={{ mb: 1 }}>
        Showing {data?.items.length ?? 0} of {data?.totalCount ?? 0} matching devices ({data?.totalDeviceCount ?? 0} total)
      </Typography>

      <TableContainer sx={{ flexGrow: 1, width: '100%', overflowX: 'auto' }}>
        <Table stickyHeader size="small" sx={{ minWidth: 2400 }}>
          <TableHead>
            <TableRow>
              <TableCell>{sortableHeader('name', 'Device Name')}</TableCell>
              <TableCell>{sortableHeader('serialNumber', 'Serial Number')}</TableCell>
              <TableCell>{sortableHeader('model', 'Model')}</TableCell>
              <TableCell>{sortableHeader('firmwareVersion', 'Firmware')}</TableCell>
              <TableCell>{sortableHeader('tunnelAlive', 'Tunnel')}</TableCell>
              <TableCell>{sortableHeader('ipAddress', 'IP Address')}</TableCell>
              <TableCell>{sortableHeader('hostname', 'Hostname')}</TableCell>
              <TableCell>Admin</TableCell>
              <TableCell>{sortableHeader('cloudManagementStatus', 'Inventory Status')}</TableCell>
              <TableCell>{sortableHeader('subscriptionStatus', 'Subscription Status')}</TableCell>
              <TableCell>{sortableHeader('expiryDate', 'Expiry Date')}</TableCell>
              <TableCell>{sortableHeader('criticalCveCount', 'Critical CVEs')}</TableCell>
              <TableCell>{sortableHeader('highestCvss', 'Highest CVSS')}</TableCell>
              <TableCell>{sortableHeader('latestPsirtUrl', 'PSIRT Link')}</TableCell>
              <TableCell>{sortableHeader('unableToEvaluateCount', 'Unresolved')}</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {data?.items.map((device: DeviceListItem) => (
              <TableRow hover key={device.id} onClick={() => navigate(`/devices/${device.serialNumber}`)} sx={{ cursor: 'pointer' }}>
                <TableCell>{device.name}</TableCell>
                <TableCell>{device.serialNumber}</TableCell>
                <TableCell>{device.model}</TableCell>
                <TableCell>{device.firmwareVersion}</TableCell>
                <TableCell>{device.tunnelAlive === null ? '—' : <Chip size="small" label={device.tunnelAlive ? 'Up' : 'Down'} color={device.tunnelAlive ? 'success' : 'error'} />}</TableCell>
                <TableCell>{device.ipAddress ?? '—'}</TableCell>
                <TableCell>{device.hostname ?? '—'}</TableCell>
                <TableCell>
                  {device.ipAddress ? (
                    <Tooltip title="Click to open admin interface (port 8443, fallback to 8444)">
                      <MuiLink
                        component="button"
                        onClick={(event) => {
                          event.stopPropagation();
                          openAdminInterface(device.ipAddress!);
                        }}
                        sx={{ cursor: 'pointer' }}
                      >
                        https
                      </MuiLink>
                    </Tooltip>
                  ) : (
                    '—'
                  )}
                </TableCell>
                <TableCell>{device.cloudManagementStatus}</TableCell>
                <TableCell><Chip size="small" label={device.subscriptionStatus} color={subscriptionStatusColor(device.subscriptionStatus)} /></TableCell>
                <TableCell>{device.expiryDate ? new Date(device.expiryDate).toLocaleDateString() : '—'}</TableCell>
                <TableCell>{device.criticalCveCount > 0 ? <Chip size="small" color="error" label={device.criticalCveCount} /> : 0}</TableCell>
                <TableCell>{device.highestCvss}</TableCell>
                <TableCell>{device.latestPsirtUrl ? <MuiLink href={device.latestPsirtUrl} target="_blank" rel="noopener" onClick={(event) => event.stopPropagation()}>Advisory</MuiLink> : '—'}</TableCell>
                <TableCell>{device.unableToEvaluateCount > 0 ? <Chip size="small" color="warning" variant="outlined" label={`${device.unableToEvaluateCount} uncertain`} /> : '—'}</TableCell>
              </TableRow>
            ))}
            {!loading && data?.items.length === 0 && (
              <TableRow><TableCell colSpan={15} align="center">No devices match the current filters.</TableCell></TableRow>
            )}
          </TableBody>
        </Table>
      </TableContainer>
      <TablePagination
        component="div"
        count={data?.totalCount ?? 0}
        page={page}
        onPageChange={(_, nextPage) => setPage(nextPage)}
        rowsPerPage={pageSize}
        onRowsPerPageChange={(event) => {
          setPage(0);
          setPageSize(Number(event.target.value));
        }}
        rowsPerPageOptions={[25, 50, 100, 250, 500]}
      />
    </Box>
  );
}
