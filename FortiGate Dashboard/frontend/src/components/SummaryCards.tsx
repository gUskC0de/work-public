import { Card, CardContent, Grid, Typography } from '@mui/material';
import type { DashboardSummary } from '../types';

interface Props {
  summary: DashboardSummary;
}

const CARD_DEFS: { key: keyof DashboardSummary; label: string; color?: string }[] = [
  { key: 'totalDevices', label: 'Total Devices' },
  { key: 'registeredDevices', label: 'Registered Devices', color: 'info.main' },
  { key: 'subscriptionsExpiring30Days', label: 'Expiring in 30 Days', color: 'error.main' },
  { key: 'subscriptionsExpiring90Days', label: 'Expiring in 90 Days', color: 'warning.main' },
  { key: 'devicesWithCriticalPsirts', label: 'Confirmed Critical PSIRT Devices', color: 'error.main' },
  // Deliberately distinct from the confirmed-critical card above: these are NOT known-safe.
  { key: 'devicesWithUnresolvedPsirtEvaluations', label: 'PSIRT Evaluations Uncertain', color: 'warning.main' },
  { key: 'oldFirmwareDevices', label: 'Old Firmware Devices', color: 'warning.main' }
];

export function SummaryCards({ summary }: Props) {
  return (
    <Grid container spacing={2}>
      {CARD_DEFS.map((card) => (
        <Grid key={card.key} item xs={12} sm={6} md={4} lg={3}>
          <Card variant="outlined">
            <CardContent>
              <Typography variant="body2" color="text.secondary">
                {card.label}
              </Typography>
              <Typography variant="h4" sx={{ color: card.color }}>
                {summary[card.key]}
              </Typography>
            </CardContent>
          </Card>
        </Grid>
      ))}
    </Grid>
  );
}
