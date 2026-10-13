// Expo's fetch() (used on iOS and Android) only accepts strings as header values
// and fails with "Cannot cast ... for field 'headers'" otherwise. Some callers
// pass numbers (e.g. the WebDAV "Depth" header), so convert them here.
// Headers objects and arrays are returned unchanged.
const normalizeFetchHeaders = <T>(headers: T): T => {
	if (!headers || typeof headers !== 'object' || Array.isArray(headers)) return headers;
	if (typeof Headers !== 'undefined' && headers instanceof Headers) return headers;

	const result: Record<string, string> = {};
	for (const [name, value] of Object.entries(headers)) {
		if (value === undefined || value === null) continue;
		result[name] = String(value);
	}
	return result as T;
};

export default normalizeFetchHeaders;
