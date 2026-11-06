import { useEffect, useRef, useState } from 'react';

interface QueryState<T> {
  data: T | undefined;
  loading: boolean;
  error: unknown;
}

/**
 * Minimal data-fetching hook (a lightweight stand-in for react-query) that
 * re-runs `fetcher` whenever an item in `deps` changes and ignores stale results.
 */
export function useQuery<T>(fetcher: () => Promise<T>, deps: unknown[]): QueryState<T> {
  const [state, setState] = useState<QueryState<T>>({ data: undefined, loading: true, error: undefined });
  const requestId = useRef(0);

  useEffect(() => {
    const currentRequest = ++requestId.current;
    setState((prev) => ({ ...prev, loading: true }));

    fetcher()
      .then((data) => {
        if (currentRequest === requestId.current) {
          setState({ data, loading: false, error: undefined });
        }
      })
      .catch((error) => {
        if (currentRequest === requestId.current) {
          setState((prev) => ({ ...prev, loading: false, error }));
        }
      });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);

  return state;
}
