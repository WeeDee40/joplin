// Storage format for drawings made with the native (PencilKit) ink editor.
//
// A drawing is stored as a regular `image/svg+xml` resource so that it syncs
// like any other resource and can be displayed by every Joplin client:
//
//   <svg width="W" height="H" viewBox="0 0 W H" data-joplin-ink="1">
//     <rect id="joplin-ink-paper" .../>                      opaque paper, keeps the ink readable on dark themes
//     <image id="joplin-ink-background" href="data:..."/>    optional: rasterised legacy (js-draw) drawing
//     <image id="joplin-ink-strokes" href="data:..."/>       the PencilKit strokes, rendered at 2x
//     <metadata id="joplin-pencilkit" data-version="1" data-canvas-width="768">BASE64</metadata>
//   </svg>
//
// The metadata holds `PKDrawing.dataRepresentation()`, which makes the drawing
// fully editable again on iOS. Other clients simply ignore it.
//
// The layers are kept separate so that a future version (e.g. a full-page
// canvas note) can add more layers without changing how existing drawings
// are read.

export const inkSvgFormatVersion = 1;
export const pencilKitMetadataId = 'joplin-pencilkit';
export const backgroundImageId = 'joplin-ink-background';
export const strokesImageId = 'joplin-ink-strokes';
export const paperRectId = 'joplin-ink-paper';

// Width of the drawing surface in PencilKit coordinates. The canvas is zoomed
// to fit the screen, so drawings look the same on every device and in both
// orientations (same approach as Apple's PencilKit sample code).
export const defaultCanvasWidth = 768;

export const defaultPaperColor = '#ffffff';

export interface InkBackground {
	// PNG, base64-encoded (without data: prefix)
	pngBase64: string;
	x: number;
	y: number;
	width: number;
	height: number;
}

export interface BuildInkSvgOptions {
	width: number;
	height: number;
	canvasWidth: number;
	// PNG, base64-encoded (without data: prefix). Rendered at 2x of width/height.
	strokesPngBase64: string;
	// PKDrawing.dataRepresentation(), base64-encoded
	drawingDataBase64: string;
	background?: InkBackground|null;
	paperColor?: string;
}

export interface ParsedPencilKitSvg {
	kind: 'pencilkit';
	drawingDataBase64: string;
	canvasWidth: number;
	width: number;
	height: number;
	background: InkBackground|null;
}

export interface ParsedLegacySvg {
	kind: 'legacy';
	// The original SVG. Displayed as a non-editable background layer.
	svg: string;
	// Why the file was not recognised as a PencilKit drawing. Only for logging.
	reason: 'no-metadata'|'invalid-metadata'|'unsupported-version';
}

export interface ParsedEmptySvg {
	kind: 'empty';
}

export type ParsedInkSvg = ParsedPencilKitSvg|ParsedLegacySvg|ParsedEmptySvg;

const formatNumber = (n: number) => {
	if (!Number.isFinite(n)) throw new Error(`Invalid number: ${n}`);
	return `${Math.round(n * 100) / 100}`;
};

export const normalizeBase64 = (data: string) => data.replace(/\s+/g, '');

export const isValidBase64 = (data: string) => {
	const normalized = normalizeBase64(data);
	if (!normalized.length || normalized.length % 4 !== 0) return false;
	return /^[A-Za-z0-9+/]+={0,2}$/.test(normalized);
};

const pngDataUrl = (base64: string) => `data:image/png;base64,${normalizeBase64(base64)}`;

const escapeAttribute = (value: string) => {
	return value.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
};

export const buildInkSvg = (options: BuildInkSvgOptions) => {
	if (!isValidBase64(options.drawingDataBase64)) throw new Error('buildInkSvg: drawing data is not valid base64');
	if (!isValidBase64(options.strokesPngBase64)) throw new Error('buildInkSvg: strokes image is not valid base64');
	if (options.width <= 0 || options.height <= 0) throw new Error(`buildInkSvg: invalid size ${options.width}x${options.height}`);

	const width = formatNumber(options.width);
	const height = formatNumber(options.height);
	const paperColor = escapeAttribute(options.paperColor ?? defaultPaperColor);

	const lines = [
		`<svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" data-joplin-ink="${inkSvgFormatVersion}">`,
		`<rect id="${paperRectId}" x="0" y="0" width="${width}" height="${height}" fill="${paperColor}"/>`,
	];

	const background = options.background;
	if (background) {
		if (!isValidBase64(background.pngBase64)) throw new Error('buildInkSvg: background image is not valid base64');
		lines.push(
			`<image id="${backgroundImageId}" x="${formatNumber(background.x)}" y="${formatNumber(background.y)}" width="${formatNumber(background.width)}" height="${formatNumber(background.height)}" preserveAspectRatio="none" href="${pngDataUrl(background.pngBase64)}"/>`,
		);
	}

	lines.push(
		`<image id="${strokesImageId}" x="0" y="0" width="${width}" height="${height}" preserveAspectRatio="none" href="${pngDataUrl(options.strokesPngBase64)}"/>`,
		`<metadata id="${pencilKitMetadataId}" data-version="${inkSvgFormatVersion}" data-canvas-width="${formatNumber(options.canvasWidth)}">${normalizeBase64(options.drawingDataBase64)}</metadata>`,
		'</svg>',
	);

	return lines.join('\n');
};

const parseAttributes = (attributesSource: string) => {
	const result: Record<string, string> = {};
	const regex = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/g;
	let match;
	while ((match = regex.exec(attributesSource)) !== null) {
		result[match[1]] = match[2] ?? match[3];
	}
	return result;
};

const findElementById = (svg: string, tagName: string, id: string) => {
	const regex = new RegExp(`<${tagName}\\b([^>]*?)(/>|>([\\s\\S]*?)</${tagName}\\s*>)`, 'g');
	let match;
	while ((match = regex.exec(svg)) !== null) {
		const attributes = parseAttributes(match[1]);
		if (attributes.id === id) {
			return { attributes, content: match[3] ?? '' };
		}
	}
	return null;
};

const parsePositiveNumber = (value: string|undefined, fallback: number) => {
	const n = Number(value);
	return Number.isFinite(n) && n > 0 ? n : fallback;
};

const parseNumber = (value: string|undefined, fallback: number) => {
	const n = Number(value);
	return Number.isFinite(n) ? n : fallback;
};

const parseBackground = (svg: string): InkBackground|null => {
	const element = findElementById(svg, 'image', backgroundImageId);
	if (!element) return null;

	const href = element.attributes.href ?? element.attributes['xlink:href'] ?? '';
	const match = /^data:image\/png;base64,([\s\S]*)$/.exec(href);
	if (!match || !isValidBase64(match[1])) return null;

	const width = parsePositiveNumber(element.attributes.width, 0);
	const height = parsePositiveNumber(element.attributes.height, 0);
	if (!width || !height) return null;

	return {
		pngBase64: normalizeBase64(match[1]),
		x: parseNumber(element.attributes.x, 0),
		y: parseNumber(element.attributes.y, 0),
		width,
		height,
	};
};

export const parseInkSvg = (svg: string|null|undefined): ParsedInkSvg => {
	if (!svg || !svg.trim()) return { kind: 'empty' };

	const metadata = findElementById(svg, 'metadata', pencilKitMetadataId);
	if (!metadata) return { kind: 'legacy', svg, reason: 'no-metadata' };

	const version = Number(metadata.attributes['data-version']);
	if (version !== inkSvgFormatVersion) return { kind: 'legacy', svg, reason: 'unsupported-version' };

	if (!isValidBase64(metadata.content)) return { kind: 'legacy', svg, reason: 'invalid-metadata' };

	const rootMatch = /<svg\b([^>]*)>/.exec(svg);
	const rootAttributes = rootMatch ? parseAttributes(rootMatch[1]) : {};
	const canvasWidth = parsePositiveNumber(metadata.attributes['data-canvas-width'], defaultCanvasWidth);

	return {
		kind: 'pencilkit',
		drawingDataBase64: normalizeBase64(metadata.content),
		canvasWidth,
		width: parsePositiveNumber(rootAttributes.width, canvasWidth),
		height: parsePositiveNumber(rootAttributes.height, 0),
		background: parseBackground(svg),
	};
};

// Size of an SVG as it would be displayed, from width/height or viewBox.
// Used to place a legacy drawing on the canvas.
export const svgIntrinsicSize = (svg: string): { width: number; height: number }|null => {
	const rootMatch = /<svg\b([^>]*)>/.exec(svg);
	if (!rootMatch) return null;
	const attributes = parseAttributes(rootMatch[1]);

	const width = parseFloat(attributes.width ?? '');
	const height = parseFloat(attributes.height ?? '');
	if (width > 0 && height > 0 && !/%$/.test(attributes.width) && !/%$/.test(attributes.height)) {
		return { width, height };
	}

	const viewBox = (attributes.viewBox ?? '').trim().split(/[\s,]+/).map(Number);
	if (viewBox.length === 4 && viewBox[2] > 0 && viewBox[3] > 0) {
		return { width: viewBox[2], height: viewBox[3] };
	}

	return null;
};

// Where a legacy drawing is placed on the canvas: at the top left, at its
// natural size, scaled down if it is wider than the canvas.
export const legacyBackgroundRect = (svg: string, canvasWidth: number) => {
	const size = svgIntrinsicSize(svg) ?? { width: canvasWidth, height: canvasWidth * 0.75 };
	const scale = Math.min(1, canvasWidth / size.width);
	return {
		x: 0,
		y: 0,
		width: size.width * scale,
		height: size.height * scale,
	};
};
