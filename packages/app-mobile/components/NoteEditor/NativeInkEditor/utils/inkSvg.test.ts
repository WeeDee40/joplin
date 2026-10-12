import { buildInkSvg, defaultCanvasWidth, isValidBase64, legacyBackgroundRect, parseInkSvg, ParsedPencilKitSvg, svgIntrinsicSize } from './inkSvg';

// cSpell:disable
// 1x1 transparent PNG
const tinyPng = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
const drawingData = 'd3JkAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
// cSpell:enable

describe('inkSvg', () => {
	test('should round-trip a drawing without background', () => {
		const svg = buildInkSvg({
			width: 768,
			height: 1024.5,
			canvasWidth: 768,
			strokesPngBase64: tinyPng,
			drawingDataBase64: drawingData,
		});

		expect(svg).toContain('width="768" height="1024.5" viewBox="0 0 768 1024.5"');
		expect(svg).toContain(`href="data:image/png;base64,${tinyPng}"`);

		const parsed = parseInkSvg(svg) as ParsedPencilKitSvg;
		expect(parsed.kind).toBe('pencilkit');
		expect(parsed.drawingDataBase64).toBe(drawingData);
		expect(parsed.canvasWidth).toBe(768);
		expect(parsed.width).toBe(768);
		expect(parsed.height).toBe(1024.5);
		expect(parsed.background).toBe(null);
	});

	test('should round-trip a drawing with a legacy background layer', () => {
		const svg = buildInkSvg({
			width: 768,
			height: 600,
			canvasWidth: 768,
			strokesPngBase64: tinyPng,
			drawingDataBase64: drawingData,
			background: { pngBase64: tinyPng, x: 0, y: 0, width: 500, height: 300 },
		});

		const parsed = parseInkSvg(svg) as ParsedPencilKitSvg;
		expect(parsed.kind).toBe('pencilkit');
		expect(parsed.background).toEqual({ pngBase64: tinyPng, x: 0, y: 0, width: 500, height: 300 });

		// Background must be drawn below the strokes
		expect(svg.indexOf('joplin-ink-background')).toBeLessThan(svg.indexOf('joplin-ink-strokes'));
	});

	test('should treat SVGs without metadata as legacy drawings', () => {
		const jsDrawSvg = '<svg viewBox="0 0 500 400" width="500" height="400" xmlns="http://www.w3.org/2000/svg"><path d="M0,0L10,10" fill="none" stroke="#000"/></svg>';
		expect(parseInkSvg(jsDrawSvg)).toEqual({ kind: 'legacy', svg: jsDrawSvg, reason: 'no-metadata' });
	});

	test('should ignore unrelated metadata elements', () => {
		const svg = '<svg width="10" height="10"><metadata id="other">abcd</metadata></svg>';
		expect(parseInkSvg(svg)).toMatchObject({ kind: 'legacy', reason: 'no-metadata' });
	});

	test('should fall back to legacy mode for corrupted base64 (content is never lost)', () => {
		const svg = buildInkSvg({
			width: 768,
			height: 100,
			canvasWidth: 768,
			strokesPngBase64: tinyPng,
			drawingDataBase64: drawingData,
		}).replace(drawingData, 'not*valid*base64!');

		expect(parseInkSvg(svg)).toEqual({ kind: 'legacy', svg, reason: 'invalid-metadata' });
	});

	test('should fall back to legacy mode for unknown format versions', () => {
		const svg = `<svg width="768" height="100"><metadata id="joplin-pencilkit" data-version="99">${drawingData}</metadata></svg>`;
		expect(parseInkSvg(svg)).toMatchObject({ kind: 'legacy', reason: 'unsupported-version' });
	});

	test('should drop a corrupted background but keep the strokes', () => {
		const svg = buildInkSvg({
			width: 768,
			height: 600,
			canvasWidth: 768,
			strokesPngBase64: tinyPng,
			drawingDataBase64: drawingData,
			background: { pngBase64: tinyPng, x: 0, y: 0, width: 500, height: 300 },
		}).replace(`base64,${tinyPng}"/>\n<image id="joplin-ink-strokes"`, 'base64,%%%"/>\n<image id="joplin-ink-strokes"');

		const parsed = parseInkSvg(svg) as ParsedPencilKitSvg;
		expect(parsed.kind).toBe('pencilkit');
		expect(parsed.background).toBe(null);
	});

	test('should accept base64 with line breaks and default the canvas width', () => {
		const svg = `<svg width="300" height="200"><metadata data-version="1" id='joplin-pencilkit'>\n${drawingData.substring(0, 12)}\n${drawingData.substring(12)}\n</metadata></svg>`;
		const parsed = parseInkSvg(svg) as ParsedPencilKitSvg;
		expect(parsed.kind).toBe('pencilkit');
		expect(parsed.drawingDataBase64).toBe(drawingData);
		expect(parsed.canvasWidth).toBe(defaultCanvasWidth);
		expect(parsed.width).toBe(300);
	});

	test('should return empty for missing files', () => {
		expect(parseInkSvg(null)).toEqual({ kind: 'empty' });
		expect(parseInkSvg('  ')).toEqual({ kind: 'empty' });
	});

	test('should refuse to build invalid documents', () => {
		expect(() => buildInkSvg({ width: 10, height: 10, canvasWidth: 768, strokesPngBase64: tinyPng, drawingDataBase64: '!!' })).toThrow();
		expect(() => buildInkSvg({ width: 0, height: 10, canvasWidth: 768, strokesPngBase64: tinyPng, drawingDataBase64: drawingData })).toThrow();
	});

	test.each([
		['', false],
		['abc', false],
		['abcd', true],
		['ab==', true],
		['a===', false],
		// Whitespace (e.g. line breaks in the metadata) is ignored
		['ab cd', true],
		['ab\ncd', true],
	])('isValidBase64(%j) should be %s', (input, expected) => {
		expect(isValidBase64(input)).toBe(expected);
	});

	test.each([
		['<svg width="500" height="400">', { width: 500, height: 400 }],
		['<svg width="500px" height="400px">', { width: 500, height: 400 }],
		['<svg viewBox="0 0 320 200" width="100%">', { width: 320, height: 200 }],
		['<svg viewBox="0,0,320,200">', { width: 320, height: 200 }],
		['<svg>', null],
		['not an svg', null],
	])('svgIntrinsicSize(%j)', (svg, expected) => {
		expect(svgIntrinsicSize(`${svg}</svg>`)).toEqual(expected);
	});

	test.each([
		// Smaller than the canvas: natural size
		['<svg width="500" height="400"></svg>', { x: 0, y: 0, width: 500, height: 400 }],
		// Wider than the canvas: scaled to fit
		['<svg width="1536" height="1000"></svg>', { x: 0, y: 0, width: 768, height: 500 }],
		// Unknown size: a default 4:3 area
		['<svg></svg>', { x: 0, y: 0, width: 768, height: 576 }],
	])('legacyBackgroundRect(%j)', (svg, expected) => {
		expect(legacyBackgroundRect(svg, 768)).toEqual(expected);
	});
});
