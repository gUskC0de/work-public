import * as XLSX from 'xlsx';
import type { DeviceListItem } from '../types';

export type Severity = 'Critical' | 'High' | 'Medium' | 'Low' | string;

export function severityColor(severity: Severity): 'error' | 'warning' | 'info' | 'success' | 'default' {
  switch (severity) {
    case 'Critical':
      return 'error';
    case 'High':
      return 'warning';
    case 'Medium':
      return 'info';
    case 'Low':
      return 'success';
    default:
      return 'default';
  }
}

export function subscriptionStatusColor(status: string): 'error' | 'warning' | 'success' | 'default' {
  switch (status) {
    case 'Expired':
    case 'Critical':
      return 'error';
    case 'Warning':
      return 'warning';
    case 'Healthy':
      return 'success';
    default:
      return 'default';
  }
}

const DEVICE_COLUMNS: { key: keyof DeviceListItem; label: string }[] = [
  { key: 'name', label: 'Device Name' },
  { key: 'serialNumber', label: 'Serial Number' },
  { key: 'model', label: 'Model' },
  { key: 'firmwareVersion', label: 'Firmware' },
  { key: 'tunnelAlive', label: 'Tunnel Up' },
  { key: 'ipAddress', label: 'IP Address' },
  { key: 'cloudManagementStatus', label: 'Cloud Managed' },
  { key: 'subscriptionStatus', label: 'Subscription Status' },
  { key: 'expiryDate', label: 'Expiry Date' },
  { key: 'criticalCveCount', label: 'Critical CVEs' },
  { key: 'highestCvss', label: 'Highest CVSS' },
  { key: 'latestPsirtUrl', label: 'PSIRT Link' },
  { key: 'unableToEvaluateCount', label: 'Unresolved PSIRT Evaluations' }
];

export function exportDevicesToExcel(devices: DeviceListItem[], filename = 'fortigate-devices.xlsx') {
  const rows = devices.map((d) => Object.fromEntries(DEVICE_COLUMNS.map((c) => [c.label, d[c.key] ?? ''])));
  const worksheet = XLSX.utils.json_to_sheet(rows);
  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(workbook, worksheet, 'Devices');
  XLSX.writeFile(workbook, filename);
}
