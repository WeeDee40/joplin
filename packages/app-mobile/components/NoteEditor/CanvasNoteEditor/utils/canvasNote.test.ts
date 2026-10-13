import { buildCanvasNoteBody, buildCanvasPageSvg, CanvasPageState, emptyCanvasPage, isCanvasNote, newCanvasNoteBody, parseCanvasNoteBody, parseCanvasPageSvg } from './canvasNote';

const id1 = 'a'.repeat(32);
const id2 = 'b'.repeat(32);
// 1x1 transparent PNG
const tinyPng = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

const samplePage = (): CanvasPageState => ({
	id: id1,
	template: 'lined',
	drawingDataBase64: 'AAAA',
	textBoxes: [{ id: 't1', x: 10, y: 20, width: 300, height: 24, text: 'Shopping <milk> & "bread"', fontSize: 16 }],
	images: [{ id: 'i1', x: 50, y: 60, width: 200, height: 100, mime: 'image/jpeg', dataBase64: tinyPng }],
});

describe('canvasNote', () => {
	test('should recognise canvas notes', () => {
		expect(isCanvasNote(newCanvasNoteBody())).toBe(true);
		expect(isCanvasNote(`\n  ${newCanvasNoteBody()}`)).toBe(true);
		expect(isCanvasNote('Some note\n<!-- joplin-canvas-note v1 -->')).toBe(false);
		expect(isCanvasNote('')).toBe(false);
		expect(isCanvasNote(null)).toBe(false);
	});

	test('should build and parse the note body', () => {
		const body = buildCanvasNoteBody([
			{ id: id1, textContent: 'Hello\nWorld' },
			{ id: id2, textContent: '' },
		], n => `Page ${n}`);

		expect(body).toContain(`![Page 1](:/${id1})`);
		expect(body).toContain(`![Page 2](:/${id2})`);
		expect(body).toContain('<!-- canvas-text\nHello\nWorld\n-->');
		expect(parseCanvasNoteBody(body)).toEqual([id1, id2]);
	});

	test('should keep the text box content inside the comment', () => {
		const body = buildCanvasNoteBody([{ id: id1, textContent: 'a -- b --> c\n>quote' }], n => `Page ${n}`);
		const comment = /<!-- canvas-text\n([\s\S]*?)\n-->/.exec(body)[1];
		expect(comment).not.toContain('--');
		expect(comment).toContain('a - - b - -> c');
		// Only the marker and the canvas-text comment are closed
		expect(body.match(/-->/g).length).toBe(2);
	});

	test('should strip characters that would break the image label', () => {
		const body = buildCanvasNoteBody([{ id: id1, textContent: '' }], () => 'Page [1]');
		expect(body).toContain(`![Page 1](:/${id1})`);
	});

	test('should return no pages for regular notes', () => {
		expect(parseCanvasNoteBody(`![image](:/${id1})`)).toEqual([]);
	});

	test('should round-trip a page', () => {
		const state = samplePage();
		const svg = buildCanvasPageSvg(tinyPng, state);

		expect(svg).toContain('width="595.28" height="841.89" viewBox="0 0 595.28 841.89"');
		expect(svg).toContain(`href="data:image/png;base64,${tinyPng}"`);
		// The JSON is XML-escaped
		expect(svg).not.toContain('<milk>');

		expect(parseCanvasPageSvg(svg, id1)).toEqual(state);
	});

	test('should use the resource ID when parsing', () => {
		const svg = buildCanvasPageSvg(tinyPng, samplePage());
		expect(parseCanvasPageSvg(svg, id2).id).toBe(id2);
	});

	test('should drop invalid items and default unknown values', () => {
		const state = {
			...samplePage(),
			template: 'unknown',
			textBoxes: [{ id: 't1', x: 'a', y: 0, width: 1, height: 1, text: 'x' }, { id: 't2', x: 1, y: 2, width: 3, height: 4, text: 'ok' }],
			images: [{ id: 'i1', x: 1, y: 2, width: 3, height: 4 }],
		} as unknown as CanvasPageState;
		const parsed = parseCanvasPageSvg(buildCanvasPageSvg(tinyPng, state), id1);

		expect(parsed.template).toBe('blank');
		expect(parsed.textBoxes).toEqual([{ id: 't2', x: 1, y: 2, width: 3, height: 4, text: 'ok', fontSize: 16 }]);
		expect(parsed.images).toEqual([]);
	});

	test.each([
		[null],
		[''],
		['<svg></svg>'],
		['<svg><metadata id="joplin-pencilkit" data-version="1">AAAA</metadata></svg>'],
		['<svg><metadata id="joplin-canvas-page" data-version="2">{}</metadata></svg>'],
		['<svg><metadata id="joplin-canvas-page" data-version="1">{broken</metadata></svg>'],
	])('should not parse %j as a canvas page', (svg) => {
		expect(parseCanvasPageSvg(svg, id1)).toBe(null);
	});

	test('should refuse invalid render data', () => {
		expect(() => buildCanvasPageSvg('not base64!', emptyCanvasPage(id1))).toThrow();
	});
});
