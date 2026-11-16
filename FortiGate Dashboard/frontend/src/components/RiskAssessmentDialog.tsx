import { useState } from 'react';
import {
  Alert,
  Chip,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  Link as MuiLink,
  MenuItem,
  Button,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Typography
} from '@mui/material';
import { isAxiosError } from 'axios';
import { psirtApi } from '../api/endpoints';
import type { AdvisoryRisk, DeviceListItem, RiskLevel } from '../types';

function riskColor(risk: RiskLevel): 'success' | 'warning' | 'error' {
  switch (risk) {
    case 'Low':
      return 'success';
    case 'High':
      return 'error';
    default:
      return 'warning';
  }
}

export function RiskChip({ risk, onClick }: { risk: RiskLevel; onClick?: () => void }) {
  return <Chip size="small" label={risk} color={riskColor(risk)} onClick={onClick} />;
}

const AUTO_VALUE = 'auto';

interface RiskAssessmentDialogProps {
  device: DeviceListItem | null;
  onClose: () => void;
  onChanged: () => void;
}

export function RiskAssessmentDialog({ device, onClose, onChanged }: RiskAssessmentDialogProps) {
  const [saving, setSaving] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const handleOverride = async (advisory: AdvisoryRisk, value: string) => {
    setSaving(advisory.psirtId);
    setError(null);
    try {
      await psirtApi.setRiskOverride(advisory.psirtId, value === AUTO_VALUE ? null : (value as RiskLevel));
      onChanged();
    } catch (err) {
      setError(isAxiosError(err) && err.response?.status === 403
        ? 'You need the Admin or Operator role to override risk assessments.'
        : 'Saving the risk override failed. Try again later.');
    } finally {
      setSaving(null);
    }
  };

  return (
    <Dialog open={device !== null} onClose={onClose} maxWidth="lg" fullWidth onClick={(event) => event.stopPropagation()}>
      <DialogTitle>Risk assessment — {device?.name}</DialogTitle>
      <DialogContent>
        <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
          Assessed against our baseline: no firewall management access is exposed to the internet and all management
          access is restricted to specific IPs. Overrides apply to the advisory on every affected firewall.
        </Typography>
        {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Advisory</TableCell>
              <TableCell>Severity</TableCell>
              <TableCell>CVSS</TableCell>
              <TableCell>Risk</TableCell>
              <TableCell>Reason (automatic)</TableCell>
              <TableCell sx={{ minWidth: 170 }}>Override</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {device?.affectedAdvisories.map((advisory) => (
              <TableRow key={advisory.psirtId}>
                <TableCell>
                  <MuiLink href={advisory.advisoryUrl} target="_blank" rel="noopener">{advisory.psirtId}</MuiLink>
                  <Typography variant="body2">{advisory.title}</Typography>
                </TableCell>
                <TableCell>{advisory.severity}</TableCell>
                <TableCell>{advisory.cvssScore}</TableCell>
                <TableCell><RiskChip risk={advisory.risk} /></TableCell>
                <TableCell>
                  <Typography variant="body2">{advisory.reason ?? '—'}</Typography>
                  {advisory.overrideRisk && (
                    <Typography variant="caption" color="text.secondary">Automatic: {advisory.autoRisk}</Typography>
                  )}
                </TableCell>
                <TableCell>
                  <TextField
                    select
                    size="small"
                    fullWidth
                    disabled={saving === advisory.psirtId}
                    value={advisory.overrideRisk ?? AUTO_VALUE}
                    onChange={(event) => handleOverride(advisory, event.target.value)}
                  >
                    <MenuItem value={AUTO_VALUE}>Automatic ({advisory.autoRisk})</MenuItem>
                    <MenuItem value="Low">Low</MenuItem>
                    <MenuItem value="Medium">Medium</MenuItem>
                    <MenuItem value="High">High</MenuItem>
                  </TextField>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </DialogContent>
      <DialogActions>
        <Button onClick={onClose}>Close</Button>
      </DialogActions>
    </Dialog>
  );
}
