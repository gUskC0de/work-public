import { apiClient } from './client';
import type {
  DashboardSummary,
  CloudConnectionStatus,
  DeviceDetail,
  DeviceListItem,
  ExpiringSubscription,
  PagedResult,
  PsirtAdvisory
} from '../types';

export interface DeviceQuery {
  search?: string;
  subscriptionStatus?: string;
  cloudManagementStatus?: string;
  hasCriticalCves?: boolean;
  hasPsirt?: boolean;
  hasUnresolved?: boolean;
  minimumCvss?: number;
  tunnelAlive?: boolean;
  sortBy?: string;
  descending?: boolean;
  page?: number;
  pageSize?: number;
}

export const dashboardApi = {
  getSummary: () => apiClient.get<DashboardSummary>('/dashboard').then((r) => r.data),
  getConnectionStatus: () => apiClient.get<CloudConnectionStatus>('/dashboard/connection').then((r) => r.data)
};

export const devicesApi = {
  list: (query: DeviceQuery) =>
    apiClient.get<PagedResult<DeviceListItem>>('/devices', { params: query }).then((r) => r.data),
  getBySerial: (serial: string) => apiClient.get<DeviceDetail>(`/devices/${serial}`).then((r) => r.data),
  exportCsvUrl: () => `${apiClient.defaults.baseURL}/devices/export/csv`
};

export const subscriptionsApi = {
  expiring: (withinDays = 90) =>
    apiClient.get<ExpiringSubscription[]>('/subscriptions/expiring', { params: { withinDays } }).then((r) => r.data)
};

export const psirtApi = {
  list: () => apiClient.get<PsirtAdvisory[]>('/psirt').then((r) => r.data)
};

export const syncApi = {
  triggerSync: () => apiClient.post('/sync').then((r) => r.data)
};
