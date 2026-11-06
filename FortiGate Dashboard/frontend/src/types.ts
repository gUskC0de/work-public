export interface DeviceListItem {
  id: string;
  name: string;
  serialNumber: string;
  model: string;
  firmwareVersion: string;
  cloudManagementStatus: string;
  subscriptionStatus: string;
  expiryDate: string | null;
  criticalCveCount: number;
  highestCvss: number;
  latestPsirtUrl: string | null;
  /** Advisories linked to this device that could not be confidently evaluated. Never "safe". */
  unableToEvaluateCount: number;
  /** FortiGate Cloud management tunnel; null until telemetry has reported the device. */
  tunnelAlive: boolean | null;
  ipAddress: string | null;
  hostname: string | null;
}

export interface PagedResult<T> {
  items: T[];
  totalCount: number;
  totalDeviceCount: number;
  page: number;
  pageSize: number;
}

export interface Subscription {
  subscriptionName: string;
  subscriptionType: string;
  expiryDate: string;
  daysRemaining: number;
  status: string;
}

export interface Vulnerability {
  cveId: string;
  severity: string;
  cvssScore: number;
  psirtId: string;
  advisoryUrl: string;
  /** "Affected", "UnableToEvaluate", "NotAffected" or "Unknown" — never omitted. */
  correlationStatus: string;
}

export interface DeviceDetail {
  id: string;
  name: string;
  serialNumber: string;
  model: string;
  firmwareVersion: string;
  cloudManagementStatus: string;
  lastSeenAt: string | null;
  tunnelAlive: boolean | null;
  ipAddress: string | null;
  hostname: string | null;
  subscriptions: Subscription[];
  vulnerabilities: Vulnerability[];
}

export interface DashboardSummary {
  totalDevices: number;
  registeredDevices: number;
  subscriptionsExpiring30Days: number;
  subscriptionsExpiring90Days: number;
  devicesWithCriticalPsirts: number;
  oldFirmwareDevices: number;
  devicesWithUnresolvedPsirtEvaluations: number;
}

export interface SyncStageStatus {
  name: string;
  status: string | null;
  lastStartedAt: string | null;
  lastCompletedAt: string | null;
  recordsProcessed: number | null;
}

export interface CloudConnectionStatus {
  credentialsConfigured: boolean;
  missingSettings: string[];
  stages: SyncStageStatus[];
}

export interface PsirtAdvisory {
  psirtId: string;
  title: string;
  advisoryUrl: string;
  severity: string;
  cvssScore: number;
  publishedDate: string;
  affectedVersionRange: string;
  affectedDeviceCount: number;
  /** "Parsed", "PartiallyParsed", "Unparseable" or "Unknown" (legacy/unassessed). */
  parseStatus: string;
}

export interface ExpiringSubscription {
  deviceName: string;
  serialNumber: string;
  subscriptionName: string;
  subscriptionType: string;
  expiryDate: string;
  daysRemaining: number;
  status: string;
}
