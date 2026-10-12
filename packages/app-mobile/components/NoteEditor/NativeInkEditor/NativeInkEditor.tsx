import * as React from 'react';
import { useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, Alert, AppState, StyleSheet, Text, View } from 'react-native';
import { _ } from '@joplin/lib/locale';
import shim from '@joplin/lib/shim';
import Logger from '@joplin/utils/Logger';
import { themeStyle } from '../../global-style';
import { ThemeAppearance } from '@joplin/lib/themes/type';
import { DialogContext } from '../../DialogManager';
import BackButtonService from '../../../services/BackButtonService';
import TextButton, { ButtonType } from '../../buttons/TextButton';
import { clearAutosave, writeAutosave } from '../ImageEditor/autosave';
import { getNativeInkView, JoplinInkViewMethods, LoadDrawingOptions } from '../../../modules/joplin-ink';
import { buildInkSvg, defaultCanvasWidth, defaultPaperColor, InkBackground, legacyBackgroundRect, parseInkSvg } from './utils/inkSvg';

const logger = Logger.create('NativeInkEditor');

// Wait this long after the last stroke before writing the autosave file
const autosaveDelayMs = 2000;

export interface DrawingSaveDetails {
	// Text recognised in the drawing (handwriting OCR). Undefined if
	// recognition was not run.
	ocrText?: string;
}

type OnSaveCallback = (svgData: string, details?: DrawingSaveDetails)=> Promise<void>;
type OnCancelCallback = ()=> void;

// Same interface as ImageEditor, so that Note.tsx can switch between both.
interface Props {
	themeId: number;
	resourceFilename: string|null;
	onSave: OnSaveCallback;
	onExit: OnCancelCallback;
}

const useStyles = (themeId: number) => {
	return useMemo(() => {
		const theme = themeStyle(themeId);
		return StyleSheet.create({
			container: {
				flex: 1,
				backgroundColor: theme.backgroundColor,
			},
			toolbar: {
				flexDirection: 'row',
				alignItems: 'center',
				justifyContent: 'space-between',
				paddingHorizontal: 4,
				minHeight: 48,
				backgroundColor: theme.backgroundColor2,
				borderBottomWidth: StyleSheet.hairlineWidth,
				borderBottomColor: theme.dividerColor,
			},
			title: {
				color: theme.color2,
				fontSize: theme.fontSize,
				fontWeight: '600',
			},
			canvas: {
				flex: 1,
			},
			loadingOverlay: {
				position: 'absolute', top: 0, left: 0, right: 0, bottom: 0,
				alignItems: 'center',
				justifyContent: 'center',
				backgroundColor: theme.backgroundColor,
			},
		});
	}, [themeId]);
};

const NativeInkEditor: React.FC<Props> = props => {
	const InkView = useMemo(() => getNativeInkView(), []);
	const inkViewRef = useRef<JoplinInkViewMethods|null>(null);
	const dialogs = useContext(DialogContext);
	const styles = useStyles(props.themeId);
	const theme = themeStyle(props.themeId);
	const darkMode = theme.appearance === ThemeAppearance.Dark;

	const [loaded, setLoaded] = useState(false);
	const [busy, setBusy] = useState(false);
	const [changed, setChanged] = useState(false);
	const changedRef = useRef(false);
	changedRef.current = changed;

	// Background layer (rasterised legacy drawing) that must be written back
	// on save.
	const backgroundRef = useRef<InkBackground|null>(null);
	const canvasWidthRef = useRef(defaultCanvasWidth);

	const onSaveRef = useRef(props.onSave);
	onSaveRef.current = props.onSave;
	const onExitRef = useRef(props.onExit);
	onExitRef.current = props.onExit;

	const exportSvg = useCallback(async (recognizeText: boolean) => {
		const result = await inkViewRef.current.exportDrawing({ recognizeText });
		const svg = buildInkSvg({
			width: result.width,
			height: result.height,
			canvasWidth: result.canvasWidth,
			strokesPngBase64: result.strokesPngBase64,
			drawingDataBase64: result.drawingDataBase64,
			background: backgroundRef.current,
		});
		return { svg, ocrText: result.ocrText, isEmpty: result.isEmpty };
	}, []);

	// Load the drawing
	const resourceFilename = props.resourceFilename;
	useEffect(() => {
		let cancelled = false;

		const load = async () => {
			const svg = resourceFilename ? await shim.fsDriver().readFile(resourceFilename, 'utf8') : null;
			const parsed = parseInkSvg(svg);

			let options: LoadDrawingOptions = { canvasWidth: defaultCanvasWidth };
			let isLegacy = false;

			if (parsed.kind === 'pencilkit') {
				options = {
					canvasWidth: parsed.canvasWidth,
					drawingDataBase64: parsed.drawingDataBase64,
				};
				if (parsed.background) {
					options = {
						...options,
						backgroundPngBase64: parsed.background.pngBase64,
						backgroundX: parsed.background.x,
						backgroundY: parsed.background.y,
						backgroundWidth: parsed.background.width,
						backgroundHeight: parsed.background.height,
					};
				}
				backgroundRef.current = parsed.background;
			} else if (parsed.kind === 'legacy') {
				logger.info(`Opening a drawing without PencilKit data (${parsed.reason}). It will be shown as a background layer.`);
				const rect = legacyBackgroundRect(parsed.svg, defaultCanvasWidth);
				options = {
					canvasWidth: defaultCanvasWidth,
					legacySvg: parsed.svg,
					backgroundX: rect.x,
					backgroundY: rect.y,
					backgroundWidth: rect.width,
					backgroundHeight: rect.height,
				};
				isLegacy = true;
			}

			canvasWidthRef.current = options.canvasWidth;
			const result = await inkViewRef.current.loadDrawing(options);
			if (cancelled) return;

			if (result.background) {
				backgroundRef.current = result.background;
			}
			setLoaded(true);

			if (isLegacy) {
				Alert.alert(
					_('Drawing from the previous editor'),
					_('This drawing was created with the previous drawing editor. You can keep drawing on it, but its existing content can no longer be edited stroke by stroke.'),
				);
			}

			void inkViewRef.current.showToolPicker();
		};

		const loadOrExit = async () => {
			try {
				await load();
			} catch (error) {
				if (cancelled) return;
				logger.error('Failed to load drawing', error);
				// Never risk overwriting a drawing that could not be loaded
				Alert.alert(_('Error'), _('The drawing could not be opened: %s', error?.message ?? String(error)));
				onExitRef.current();
			}
		};
		void loadOrExit();

		return () => {
			cancelled = true;
		};
	}, [resourceFilename]);

	// Autosave, so that nothing is lost if the app is closed while drawing.
	// Uses the same file as the js-draw editor, so the existing "restore
	// autosaved drawing" prompt in the note screen also works for this editor.
	const autosaveTimeoutRef = useRef<ReturnType<typeof setTimeout>|null>(null);
	const autosaveNow = useCallback(async () => {
		if (autosaveTimeoutRef.current) {
			clearTimeout(autosaveTimeoutRef.current);
			autosaveTimeoutRef.current = null;
		}
		if (!changedRef.current || !inkViewRef.current) return;

		try {
			const { svg } = await exportSvg(false);
			await writeAutosave(svg);
		} catch (error) {
			logger.warn('Autosave failed', error);
		}
	}, [exportSvg]);

	const onDrawingChanged = useCallback(() => {
		setChanged(true);
		changedRef.current = true;

		if (autosaveTimeoutRef.current) clearTimeout(autosaveTimeoutRef.current);
		autosaveTimeoutRef.current = setTimeout(() => {
			void autosaveNow();
		}, autosaveDelayMs);
	}, [autosaveNow]);

	useEffect(() => {
		const subscription = AppState.addEventListener('change', state => {
			if (state !== 'active') void autosaveNow();
		});
		return () => {
			subscription.remove();
			if (autosaveTimeoutRef.current) clearTimeout(autosaveTimeoutRef.current);
		};
	}, [autosaveNow]);

	const discardAndExit = useCallback(async () => {
		if (autosaveTimeoutRef.current) clearTimeout(autosaveTimeoutRef.current);
		changedRef.current = false;
		await clearAutosave();
		onExitRef.current();
	}, []);

	const saveAndExit = useCallback(async () => {
		if (busy) return;
		setBusy(true);
		try {
			const { svg, ocrText, isEmpty } = await exportSvg(true);
			if (isEmpty && !resourceFilename) {
				// Nothing drawn: don't attach an empty drawing
				await discardAndExit();
				return;
			}

			await onSaveRef.current(svg, { ocrText });
			await discardAndExit();
		} catch (error) {
			logger.error('Failed to save drawing', error);
			setBusy(false);
			// The autosave file is kept, so the drawing can still be recovered
			dialogs.prompt(_('Error'), _('The drawing could not be saved: %s', error?.message ?? String(error)));
		}
	}, [busy, exportSvg, resourceFilename, discardAndExit, dialogs]);

	const onDone = useCallback(() => {
		if (!changed) {
			void discardAndExit();
		} else {
			void saveAndExit();
		}
	}, [changed, discardAndExit, saveAndExit]);

	const onCancel = useCallback(() => {
		if (!changed) {
			void discardAndExit();
			return;
		}

		dialogs.prompt(
			_('Save changes?'), _('This drawing may have unsaved changes.'), [
				{
					text: _('Discard changes'),
					onPress: () => void discardAndExit(),
					style: 'destructive',
				},
				{
					text: _('Save changes'),
					onPress: () => void saveAndExit(),
				},
			],
		);
	}, [changed, dialogs, discardAndExit, saveAndExit]);

	useEffect(() => {
		const hardwareBackPressListener = () => {
			onCancel();
			return true;
		};
		BackButtonService.addHandler(hardwareBackPressListener);
		return () => {
			BackButtonService.removeHandler(hardwareBackPressListener);
		};
	}, [onCancel]);

	const paperColor = darkMode ? theme.backgroundColor : defaultPaperColor;

	return (
		<View style={styles.container}>
			<View style={styles.toolbar}>
				<TextButton type={ButtonType.Link} onPress={onCancel} disabled={busy}>{_('Cancel')}</TextButton>
				<Text style={styles.title} accessibilityRole='header'>{_('Drawing')}</Text>
				<TextButton type={ButtonType.Link} onPress={onDone} disabled={busy || !loaded}>{_('Done')}</TextButton>
			</View>
			<View style={styles.canvas}>
				<InkView
					ref={inkViewRef}
					style={styles.canvas}
					darkMode={darkMode}
					paperColor={paperColor}
					onDrawingChanged={onDrawingChanged}
				/>
				{(!loaded || busy) && <View style={[styles.loadingOverlay, loaded && { backgroundColor: 'transparent' }]}>
					<ActivityIndicator size='large' color={theme.color} accessibilityLabel={busy ? _('Saving...') : _('Loading...')} />
				</View>}
			</View>
		</View>
	);
};

export default NativeInkEditor;
