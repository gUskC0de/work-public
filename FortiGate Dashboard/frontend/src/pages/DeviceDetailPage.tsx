import {
  Alert,
  Card,
  CardContent,
  Chip,
  CircularProgress,
  Grid,
  Link as MuiLink,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  Typography
} from '@mui/material';
import { useParams } from 'react-router-dom';
import { useQuery } from '../hooks/useQuery';
import { devicesApi } from '../api/endpoints';
import { severityColor, subscriptionStatusColor } from '../utils/formatting';

export function DeviceDetailPage() {
  const { serial } = useParams<{ serial: string }>();
  const { data: device, loading, error } = useQuery(() => devicesApi.getBySerial(serial!), [serial]);

  if (loading) return <CircularProgress />;
  if (error || !device) return <Alert severity="error">Failed to load device {serial}.</Alert>;

  return (
    <Stack spacing={3}>
      <Typography variant="h4">{device.name}</Typography>

      <Grid container spacing={2}>
        <Grid item xs={12} md={4}>
          <Card variant="outlined">
            <CardContent>
              <Typography variant="h6" gutterBottom>
                Basic Information
              </Typography>
              <Typography>Serial Number: {device.serialNumber}</Typography>
              <Typography>Model: {device.model}</Typography>
              <Typography>Firmware: {device.firmwareVersion}</Typography>
              <Typography>
                Tunnel: {device.tunnelAlive === null ? 'Not reported' : device.tunnelAlive ? 'Up' : 'Down'}
              </Typography>
              <Typography>IP Address: {device.ipAddress ?? 'Not reported'}</Typography>
              <Typography>Hostname: {device.hostname ?? 'Not reported'}</Typography>
              <Typography>Inventory Status: {device.cloudManagementStatus}</Typography>
              <Typography>
                Last Seen: {device.lastSeenAt ? new Date(device.lastSeenAt).toLocaleString() : 'Never'}
              </Typography>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12} md={8}>
          <Card variant="outlined">
            <CardContent>
              <Typography variant="h6" gutterBottom>
                Subscriptions
              </Typography>
              <TableContainer>
                <Table size="small">
                  <TableHead>
                    <TableRow>
                      <TableCell>Name</TableCell>
                      <TableCell>Type</TableCell>
                      <TableCell>Expiry</TableCell>
                      <TableCell>Days Remaining</TableCell>
                      <TableCell>Status</TableCell>
                    </TableRow>
                  </TableHead>
                  <TableBody>
                    {device.subscriptions.map((s) => (
                      <TableRow key={s.subscriptionName + s.subscriptionType}>
                        <TableCell>{s.subscriptionName}</TableCell>
                        <TableCell>{s.subscriptionType}</TableCell>
                        <TableCell>{new Date(s.expiryDate).toLocaleDateString()}</TableCell>
                        <TableCell>{s.daysRemaining}</TableCell>
                        <TableCell>
                          <Chip size="small" label={s.status} color={subscriptionStatusColor(s.status)} />
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </TableContainer>
            </CardContent>
          </Card>
        </Grid>

        <Grid item xs={12}>
          <Card variant="outlined">
            <CardContent>
              <Typography variant="h6" gutterBottom>
                Vulnerabilities
              </Typography>
              <TableContainer>
                <Table size="small">
                  <TableHead>
                    <TableRow>
                      <TableCell>CVE</TableCell>
                      <TableCell>Severity</TableCell>
                      <TableCell>CVSS</TableCell>
                      <TableCell>PSIRT ID</TableCell>
                      <TableCell>Status</TableCell>
                      <TableCell>Advisory</TableCell>
                    </TableRow>
                  </TableHead>
                  <TableBody>
                    {device.vulnerabilities.map((v) => (
                      <TableRow key={v.cveId}>
                        <TableCell>{v.cveId}</TableCell>
                        <TableCell>
                          <Chip size="small" label={v.severity} color={severityColor(v.severity)} />
                        </TableCell>
                        <TableCell>{v.cvssScore.toFixed(1)}</TableCell>
                        <TableCell>{v.psirtId}</TableCell>
                        <TableCell>
                          {v.correlationStatus === 'Affected' ? (
                            <Chip size="small" color="error" label="Confirmed affected" />
                          ) : (
                            <Chip size="small" color="warning" variant="outlined" label="Unable to evaluate" />
                          )}
                        </TableCell>
                        <TableCell>
                          <MuiLink href={v.advisoryUrl} target="_blank" rel="noopener">
                            View advisory
                          </MuiLink>
                        </TableCell>
                      </TableRow>
                    ))}
                    {device.vulnerabilities.length === 0 && (
                      <TableRow>
                        <TableCell colSpan={6}>No known vulnerabilities for this firmware version.</TableCell>
                      </TableRow>
                    )}
                  </TableBody>
                </Table>
              </TableContainer>
            </CardContent>
          </Card>
        </Grid>
      </Grid>
    </Stack>
  );
}
