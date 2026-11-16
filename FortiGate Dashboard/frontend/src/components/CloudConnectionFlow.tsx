import { useState } from 'react';
import {
  Alert,
  Box,
  Button,
  Chip,
  CircularProgress,
  Divider,
  Paper,
  Stack,
  Typography
} from '@mui/material';
import RefreshIcon from '@mui/icons-material/Refresh';
import { dashboardApi } from '../api/endpoints';
import { useQuery } from '../hooks/useQuery';
import type { SyncStageStatus } from '../types';

function stageLabel(status: string | null): { label: string; color: 'success' | 'warning' | 'error' | 'default' } {
  switch (status) {
    case 'Succeeded':
      return { label: 'Synced', color: 'success' };
    case 'PartiallySucceeded':
      return { label: 'Partial', color: 'warning' };
    case 'Failed':
      return { label: 'Failed', color: 'error' };
    case 'Running':
      return { label: 'Running', color: 'warning' };
    default:
      return { label: 'Not run yet', color: 'default' };
  }
}

function formatDate(value: string | null): string {
  return value ? new Date(value).toLocaleString() : 'No completed sync recorded';
}

function SyncStage({ stage }: { stage: SyncStageStatus }) {
  const state = stageLabel(stage.status);
  return (
    <Box sx={{ py: 1.5 }}>
      <Stack direction={{ xs: 'column', sm: 'row' }} spacing={1} alignItems={{ sm: 'center' }}>
        <Typography variant="subtitle1" sx={{ minWidth: 220, fontWeight: 600 }}>
          {stage.name === 'DeviceInventory' ? 'Device inventory' : stage.name === 'SubscriptionInfo' ? 'Subscriptions' : 'PSIRT advisories'}
        </Typography>
        <Chip size="small" label={state.label} color={state.color} variant={state.color === 'default' ? 'outlined' : 'filled'} />
        <Typography variant="body2" color="text.secondary">
          {formatDate(stage.lastCompletedAt)}
          {stage.recordsProcessed !== null ? ` · ${stage.recordsProcessed.toLocaleString()} records` : ''}
        </Typography>
      </Stack>
    </Box>
  );
}

export function CloudConnectionFlow() {
  const [refreshKey, setRefreshKey] = useState(0);
  const { data, loading, error } = useQuery(() => dashboardApi.getConnectionStatus(), [refreshKey]);

  return (
    <Paper variant="outlined" sx={{ p: { xs: 2, md: 3 } }}>
      <Stack direction={{ xs: 'column', sm: 'row' }} spacing={1} alignItems={{ sm: 'center' }} sx={{ mb: 1 }}>
        <Typography variant="h6" sx={{ flexGrow: 1 }}>FortiGate Cloud connection</Typography>
        <Button size="small" startIcon={<RefreshIcon />} onClick={() => setRefreshKey((value) => value + 1)}>
          Refresh status
        </Button>
      </Stack>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Configuration is checked locally. A successful inventory sync is the evidence that the API credentials reached FortiGate Cloud.
      </Typography>

      {loading && <CircularProgress size={24} />}
      {!!error && <Alert severity="error" sx={{ mb: 2 }}>Could not load connection status.</Alert>}
      {data && (
        <>
          <Stack direction="row" spacing={1} alignItems="center" sx={{ mb: 1.5 }}>
            <Chip
              size="small"
              color={data.credentialsConfigured ? 'success' : 'warning'}
              label={data.credentialsConfigured ? 'Required settings present' : 'Configuration incomplete'}
            />
            <Typography variant="body2" color="text.secondary">Secret values are not returned to the browser.</Typography>
          </Stack>
          {!data.credentialsConfigured && (
            <Alert severity="warning" sx={{ mb: 1.5 }}>
              Configure these API settings: {data.missingSettings.join(', ')}.
            </Alert>
          )}
          <Divider />
          {data.stages.map((stage) => <SyncStage key={stage.name} stage={stage} />)}
        </>
      )}
    </Paper>
  );
}