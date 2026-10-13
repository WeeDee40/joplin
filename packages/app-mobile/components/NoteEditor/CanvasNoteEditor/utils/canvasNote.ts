// Storage format of canvas notes.
//
// A canvas note is a regular Markdown note, so that every Joplin client can
// display and search it:
//
//   <!-- joplin-canvas-note v1 -->
//
//   ![Page 1](:/<resource id>)
//   <!-- canvas-text
//   Text of the text boxes on page 1 (hidden, but indexed by the search)
//   -->
//
//   ![Page 2](:/<resource id>)
//
// Each page is an `image/svg+xml` resource with a rendered image of the whole
// page (paper, images, strokes, text) and the editable state as JSON:
//
//   <svg width="595.28" height="841.89" ... data-joplin-canvas-page="1">
//     <image id="joplin-canvas-render" href="data:image/png;base64,..."/>
//     <metadata id="joplin-canvas-page" data-version="1">{ JSON, XML-escaped }</metadata>
//   </svg>

export const canvasNoteMarker = '<!-- joplin-canvas-note v1 -->';
export const canvasPageFormatVersion = 1;
export const canvasPageMetadataId = 'joplin-canvas-page';
export const canvasPageRenderId = 'joplin-canvas-render';

// A4 in points
export const canvasPageWidth = 595.28;
export const canvasPageHeight = 841.89;

export type PaperTemplate = 'blank'|'lined'|'grid';

export interface CanvasTextBox {
	id: string;
	x: number;
	y: number;
	width: number;
	height: number;
	text: string;
	fontSize: number;
}

export interface CanvasImage {
	id: string;
	x: number;
	y: number;
	width: number;
	height: number;
	mime: string;
	dataBase64: string;
}

export interface CanvasPageState {
	id: string;
	template: PaperTemplate;
	drawingDataBase64: string;
	textBoxes: CanvasTextBox[];
	images: CanvasImage[];
}

export interface CanvasNotePage {
	id: string;
	textContent: string;
}

const resourceIdPattern = '[0-9a-zA-Z]{32}';

export const isCanvasNote = (body: string|null|undefined) => {
	return !!body && body.trimStart().startsWith(canvasNoteMarker);
};

export const newCanvasNoteBody = () => `${canvasNoteMarker}\n`;

// IDs of the page resources, in page order
export const parseCanvasNoteBody = (body: string): string[] => {
	if (!isCanvasNote(body)) return [];
	const regex = new RegExp(`!\\[[^\\]]*\\]\\(:\\/(${resourceIdPattern})\\)`, 'g');
	const ids: string[] = [];
	let match;
	while ((match = regex.exec(body)) !== null) {
		if (!ids.includes(match[1])) ids.push(match[1]);
	}
	return ids;
};

// Text inside an HTML comment must not contain "--" (and therefore no "-->")
const escapeCommentText = (text: string) => {
	return text.replace(/-{2,}/g, match => match.split('').join(' ')).replace(/^>/gm, ' >');
};

const escapeMarkdownLabel = (label: string) => label.replace(/[[\]\\]/g, '');

export const buildCanvasNoteBody = (pages: CanvasNotePage[], pageLabel: (pageNumber: number)=> string) => {
	const parts = [canvasNoteMarker];
	for (let index = 0; index < pages.length; index++) {
		const page = pages[index];
		let part = `![${escapeMarkdownLabel(pageLabel(index + 1))}](:/${page.id})`;
		const text = page.textContent.trim();
		if (text) {
			part += `\n<!-- canvas-text\n${escapeCommentText(text)}\n-->`;
		}
		parts.push(part);
	}
	return `${parts.join('\n\n')}\n`;
};

const escapeXml = (text: string) => {
	return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
};

const unescapeXml = (text: string) => {
	return text.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, '\'').replace(/&amp;/g, '&');
};

const formatNumber = (n: number) => `${Math.round(n * 100) / 100}`;

export const buildCanvasPageSvg = (renderPngBase64: string, state: CanvasPageState) => {
	if (!/^[A-Za-z0-9+/]+={0,2}$/.test(renderPngBase64)) {
		throw new Error('buildCanvasPageSvg: render is not valid base64');
	}
	const width = formatNumber(canvasPageWidth);
	const height = formatNumber(canvasPageHeight);
	return [
		`<svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" data-joplin-canvas-page="${canvasPageFormatVersion}">`,
		`<image id="${canvasPageRenderId}" x="0" y="0" width="${width}" height="${height}" preserveAspectRatio="none" href="data:image/png;base64,${renderPngBase64}"/>`,
		`<metadata id="${canvasPageMetadataId}" data-version="${canvasPageFormatVersion}">${escapeXml(JSON.stringify(state))}</metadata>`,
		'</svg>',
	].join('\n');
};

const isPaperTemplate = (value: unknown): value is PaperTemplate => {
	return value === 'blank' || value === 'lined' || value === 'grid';
};

const isFiniteNumber = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value);

const isValidItem = (item: Record<string, unknown>) => {
	return typeof item?.id === 'string'
		&& isFiniteNumber(item.x) && isFiniteNumber(item.y)
		&& isFiniteNumber(item.width) && isFiniteNumber(item.height);
};

// Returns null if the SVG is not a canvas page (or the data is damaged).
// `resourceId` overrides the ID stored in the page.
export const parseCanvasPageSvg = (svg: string|null|undefined, resourceId: string): CanvasPageState|null => {
	if (!svg) return null;
	const match = new RegExp(`<metadata\\b([^>]*)\\bid="${canvasPageMetadataId}"([^>]*)>([\\s\\S]*?)</metadata>`).exec(svg);
	if (!match) return null;

	const versionMatch = /data-version="(\d+)"/.exec(`${match[1]} ${match[2]}`);
	if (!versionMatch || Number(versionMatch[1]) !== canvasPageFormatVersion) return null;

	let data: Record<string, unknown>;
	try {
		data = JSON.parse(unescapeXml(match[3]));
	} catch (error) {
		return null;
	}
	if (!data || typeof data !== 'object') return null;

	const textBoxes = Array.isArray(data.textBoxes) ? data.textBoxes : [];
	const images = Array.isArray(data.images) ? data.images : [];

	return {
		id: resourceId,
		template: isPaperTemplate(data.template) ? data.template : 'blank',
		drawingDataBase64: typeof data.drawingDataBase64 === 'string' ? data.drawingDataBase64 : '',
		textBoxes: textBoxes
			.filter(item => isValidItem(item) && typeof item.text === 'string')
			.map(item => ({ ...item, fontSize: isFiniteNumber(item.fontSize) ? item.fontSize : 16 })),
		images: images.filter(item => isValidItem(item) && typeof item.dataBase64 === 'string' && typeof item.mime === 'string'),
	};
};

export const emptyCanvasPage = (id: string, template: PaperTemplate = 'blank'): CanvasPageState => ({
	id,
	template,
	drawingDataBase64: '',
	textBoxes: [],
	images: [],
});
