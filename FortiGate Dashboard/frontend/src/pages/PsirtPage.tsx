import {
  Alert,
  Chip,
  CircularProgress,
  Link as MuiLink,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TableSortLabel,
  Typography
} from '@mui/material';
import { useState } from 'react';
import { useQuery } from '../hooks/useQuery';
import { psirtApi } from '../api/endpoints';
import { severityColor } from '../utils/formatting';

type SortField = 'severity' | 'cvssScore' | 'publishedDate';
type SortDirection = 'asc' | 'desc';

const SEVERITY_ORDER: Record<string, number> = {
  Low: 0,
  Medium: 1,
  High: 2,
  Critical: 3
};

export function PsirtPage() {
  const { data, loading, error } = useQuery(() => psirtApi.list(), []);
  const [sortField, setSortField] = useState<SortField>('publishedDate');
  const [sortDirection, setSortDirection] = useState<SortDirection>('desc');

  const handleSort = (field: SortField) => {
    if (sortField === field) {
      setSortDirection((direction) => direction === 'asc' ? 'desc' : 'asc');
      return;
    }

    setSortField(field);
    setSortDirection(field === 'publishedDate' ? 'desc' : 'asc');
  };

  const sortedAdvisories = data ? [...data].sort((left, right) => {
    const comparison = sortField === 'severity'
      ? (SEVERITY_ORDER[left.severity] ?? -1) - (SEVERITY_ORDER[right.severity] ?? -1)
      : sortField === 'cvssScore'
        ? left.cvssScore - right.cvssScore
        : new Date(left.publishedDate).getTime() - new Date(right.publishedDate).getTime();

    return sortDirection === 'asc' ? comparison : -comparison;
  }) : [];

  return (
    <Stack spacing={2}>
      <Typography variant="h4">PSIRT Advisories</Typography>
      {loading && <CircularProgress />}
      {!!error && <Alert severity="error">Failed to load PSIRT advisories.</Alert>}
      {data && (
        <TableContainer>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>PSIRT ID</TableCell>
                <TableCell>Title</TableCell>
                <TableCell sortDirection={sortField === 'severity' ? sortDirection : false}>
                  <TableSortLabel active={sortField === 'severity'} direction={sortField === 'severity' ? sortDirection : 'asc'} onClick={() => handleSort('severity')}>
                    Severity
                  </TableSortLabel>
                </TableCell>
                <TableCell sortDirection={sortField === 'cvssScore' ? sortDirection : false}>
                  <TableSortLabel active={sortField === 'cvssScore'} direction={sortField === 'cvssScore' ? sortDirection : 'asc'} onClick={() => handleSort('cvssScore')}>
                    CVSS
                  </TableSortLabel>
                </TableCell>
                <TableCell sortDirection={sortField === 'publishedDate' ? sortDirection : false}>
                  <TableSortLabel active={sortField === 'publishedDate'} direction={sortField === 'publishedDate' ? sortDirection : 'desc'} onClick={() => handleSort('publishedDate')}>
                    Published
                  </TableSortLabel>
                </TableCell>
                <TableCell>Confirmed Affected Devices</TableCell>
                <TableCell>Parse Status</TableCell>
                <TableCell>Advisory</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {sortedAdvisories.map((advisory) => (
                <TableRow key={advisory.psirtId}>
                  <TableCell>{advisory.psirtId}</TableCell>
                  <TableCell>{advisory.title}</TableCell>
                  <TableCell>
                    <Chip size="small" label={advisory.severity} color={severityColor(advisory.severity)} />
                  </TableCell>
                  <TableCell>{advisory.cvssScore.toFixed(1)}</TableCell>
                  <TableCell>{new Date(advisory.publishedDate).toLocaleDateString()}</TableCell>
                  <TableCell>{advisory.affectedDeviceCount}</TableCell>
                  <TableCell>
                    {advisory.parseStatus === 'Parsed' ? (
                      <Chip size="small" color="success" variant="outlined" label="Parsed" />
                    ) : (
                      <Chip size="small" color="warning" variant="outlined" label={advisory.parseStatus} />
                    )}
                  </TableCell>
                  <TableCell>
                    <MuiLink href={advisory.advisoryUrl} target="_blank" rel="noopener">
                      fortiguard.com/psirt
                    </MuiLink>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      )}
    </Stack>
  );
}
