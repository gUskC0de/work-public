import { Alert, CircularProgress, Stack, Typography } from '@mui/material';
import { useQuery } from '../hooks/useQuery';
import { dashboardApi } from '../api/endpoints';
import { SummaryCards } from '../components/SummaryCards';
import { CloudConnectionFlow } from '../components/CloudConnectionFlow';

export function DashboardPage() {
  const { data, loading, error } = useQuery(() => dashboardApi.getSummary(), []);

  return (
    <Stack spacing={3}>
      <Typography variant="h4">Dashboard</Typography>
      {loading && <CircularProgress />}
      {!!error && <Alert severity="error">Failed to load dashboard summary.</Alert>}
      {data && <SummaryCards summary={data} />}
      <CloudConnectionFlow />
    </Stack>
  );
}
