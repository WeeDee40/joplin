// JavaScript bindings for the native PencilKit view (see ./ios).
//
// The native module only exists in iOS builds. Everything here is loaded
// lazily, so that importing this file on Android, on web or in Jest is safe.

import { Platform, ViewProps } from 'react-native';
import type { ComponentType, Ref } from 'react';

export interface LoadDrawingOptions {
	drawingDataBase64?: string|null;
	canvasWidth: number;

	backgroundPngBase64?: string|null;
	backgroundX?: number;
	backgroundY?: number;
	backgroundWidth?: number;
	backgroundHeight?: number;

	// Rasterised and shown as a non-editable background layer
	legacySvg?: string|null;
}

export interface LoadDrawingResult {
	// Set when a legacy SVG was rasterised
	background?: {
		pngBase64: string;
		x: number;
		y: number;
		width: number;
		height: number;
	};
}

export interface ExportDrawingOptions {
	recognizeText: boolean;
	recognitionLanguages?: string[];
}

export interface ExportDrawingResult {
	// True if there are neither strokes nor a background layer
	isEmpty: boolean;
	width: number;
	height: number;
	canvasWidth: number;
	strokesPngBase64: string;
	drawingDataBase64: string;
	ocrText?: string;
}

export interface JoplinInkViewMethods {
	loadDrawing(options: LoadDrawingOptions): Promise<LoadDrawingResult>;
	exportDrawing(options: ExportDrawingOptions): Promise<ExportDrawingResult>;
	// Shows the PencilKit tool picker and makes the canvas first responder
	showToolPicker(): Promise<void>;
}

export interface JoplinInkViewProps extends ViewProps {
	ref?: Ref<JoplinInkViewMethods>;
	darkMode: boolean;
	paperColor: string;
	// Sent once the native view is mounted. Methods can only be called after that.
	onReady?: ()=> void;
	onDrawingChanged?: ()=> void;
}

const moduleName = 'JoplinInk';

let nativeView: ComponentType<JoplinInkViewProps>|null = null;

export const isNativeInkAvailable = () => {
	if (Platform.OS !== 'ios') return false;

	try {
		// eslint-disable-next-line @typescript-eslint/no-require-imports -- Lazy-loaded: not available on all platforms
		const { requireOptionalNativeModule } = require('expo-modules-core');
		return !!requireOptionalNativeModule(moduleName);
	} catch (error) {
		// E.g. in tests, where native modules are not available
		return false;
	}
};

export const getNativeInkView = (): ComponentType<JoplinInkViewProps> => {
	if (!nativeView) {
		// eslint-disable-next-line @typescript-eslint/no-require-imports -- Lazy-loaded: not available on all platforms
		const { requireNativeViewManager } = require('expo-modules-core');
		nativeView = requireNativeViewManager(moduleName);
	}
	return nativeView;
};

// Canvas notes (see ios/Canvas)

export type CanvasPaperTemplate = 'blank'|'lined'|'grid';

export interface CanvasExportOptions {
	recognizeText: boolean;
	recognitionLanguages?: string[];
}

export interface JoplinCanvasViewMethods {
	// Pages as JSON (CanvasPageState[]). An empty list creates one blank page.
	loadPages(pagesJson: string, initialPageId: string|null): Promise<void>;
	// Returns JSON, see CanvasPageExport in CanvasNoteEditor
	exportPages(options: CanvasExportOptions): Promise<string>;
	markAllUnsaved(): Promise<void>;
	addPage(template: CanvasPaperTemplate|null): Promise<void>;
	deleteCurrentPage(): Promise<void>;
	setTemplate(template: CanvasPaperTemplate): Promise<void>;
	addTextBox(): Promise<void>;
	insertImage(): Promise<void>;
	sharePdf(title: string): Promise<void>;
	showToolPicker(): Promise<void>;
}

export interface CanvasViewState {
	pageCount: number;
	currentPage: number;
	template: CanvasPaperTemplate;
}

export interface JoplinCanvasViewProps extends ViewProps {
	ref?: Ref<JoplinCanvasViewMethods>;
	darkMode: boolean;
	onReady?: ()=> void;
	onChanged?: ()=> void;
	onStateChanged?: (event: { nativeEvent: CanvasViewState })=> void;
}

const canvasModuleName = 'JoplinCanvas';
let nativeCanvasView: ComponentType<JoplinCanvasViewProps>|null = null;

export const isNativeCanvasAvailable = () => {
	if (Platform.OS !== 'ios') return false;

	try {
		// eslint-disable-next-line @typescript-eslint/no-require-imports -- Lazy-loaded: not available on all platforms
		const { requireOptionalNativeModule } = require('expo-modules-core');
		return !!requireOptionalNativeModule(canvasModuleName);
	} catch (error) {
		// E.g. in tests, where native modules are not available
		return false;
	}
};

export const getNativeCanvasView = (): ComponentType<JoplinCanvasViewProps> => {
	if (!nativeCanvasView) {
		// eslint-disable-next-line @typescript-eslint/no-require-imports -- Lazy-loaded: not available on all platforms
		const { requireNativeViewManager } = require('expo-modules-core');
		nativeCanvasView = requireNativeViewManager(canvasModuleName);
	}
	return nativeCanvasView;
};
