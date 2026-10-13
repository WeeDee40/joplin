import normalizeFetchHeaders from './normalizeFetchHeaders';

describe('normalizeFetchHeaders', () => {
	test('should convert header values to strings', () => {
		expect(normalizeFetchHeaders({ Depth: 1, 'Content-Length': 42, Accept: 'text/xml' })).toEqual({
			Depth: '1',
			'Content-Length': '42',
			Accept: 'text/xml',
		});
	});

	test('should drop undefined and null values', () => {
		expect(normalizeFetchHeaders({ A: undefined, B: null, C: 'c' } as Record<string, unknown>)).toEqual({ C: 'c' });
	});

	test.each([
		[undefined],
		[null],
		[[['Depth', '1']]],
	])('should return %j unchanged', (headers) => {
		expect(normalizeFetchHeaders(headers)).toBe(headers);
	});
});
