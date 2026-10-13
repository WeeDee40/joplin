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

	// eslint-disable-next-line @typescript-eslint/no-require-imports -- Lazy-loaded: not available on all platforms
	const { requireOptionalNativeModule } = require('expo-modules-core');
	return !!requireOptionalNativeModule(moduleName);
};

export const getNativeInkView = (): ComponentType<JoplinInkViewProps> => {
	if (!nativeView) {
		// eslint-disable-next-line @typescript-eslint/no-require-imports -- Lazy-loaded: not available on all platforms
		const { requireNativeViewManager } = require('expo-modules-core');
		nativeView = requireNativeViewManager(moduleName);
	}
	return nativeView;
};
