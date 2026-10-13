import * as React from 'react';
import { useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, Alert, AppState, StyleSheet, TextInput, View } from 'react-native';
import { _ } from '@joplin/lib/locale';
import shim from '@joplin/lib/shim';
import Setting from '@joplin/lib/models/Setting';
import Resource from '@joplin/lib/models/Resource';
import { ResourceEntity } from '@joplin/lib/services/database/types';
import Logger from '@joplin/utils/Logger';
import { join } from 'path';
import { msleep } from '@joplin/utils/time';
import { themeStyle } from '../../global-style';
import { ThemeAppearance } from '@joplin/lib/themes/type';
import { DialogContext } from '../../DialogManager';
import BackButtonService from '../../../services/BackButtonService';
import TextButton, { ButtonType } from '../../buttons/TextButton';
import IconButton from '../../IconButton';
import saveDrawingOcrText from '../NativeInkEditor/utils/saveDrawingOcrText';
import { CanvasPaperTemplate, CanvasViewState, getNativeCanvasView, JoplinCanvasViewMethods } from '../../../modules/joplin-ink';
import { buildCanvasNoteBody, buildCanvasPageSvg, CanvasPageState, parseCanvasNoteBody, parseCanvasPageSvg } from './utils/canvasNote';

const logger = Logger.create('CanvasNoteEditor');

// Save this long after the last change
const autosaveDelayMs = 3000;

interface CanvasPageExport {
	id: string;
	textContent: string;
	changed: boolean;
	state?: CanvasPageState;
	renderPngBase64?: string;
	ocrText?: string;
}

interface Props {
	themeId: number;
	noteTitle: string;
	noteBody: string;
	// Page to scroll to when opening (resource ID)
	initialPageId: string|null;
	onBodyChange: (body: string)=> void|Promise<void>;
	onTitleChange: (title: string)=> void;
	onExit: ()=> void;
}

const pageLabel = (pageNumber: number) => _('Page %d', pageNumber);

// Loads the pages of a canvas note. Throws if a page cannot be used.
const loadPageStates = async (noteBody: string): Promise<CanvasPageState[]> => {
	const pages: CanvasPageState[] = [];
	for (const resourceId of parseCanvasNoteBody(noteBody)) {
		const resource: ResourceEntity = await Resource.load(resourceId);
		if (!resource) throw new Error(_('Page %d is missing.', pages.length + 1));
		if (!(await Resource.isReady(resource))) {
			throw new Error(_('Page %d has not been downloaded yet. Please sync and try again.', pages.length + 1));
		}

		const svg = await shim.fsDriver().readFile(Resource.fullPath(resource), 'utf8');
		const state = parseCanvasPageSvg(svg, resourceId);
		if (!state) throw new Error(_('Page %d is not a canvas page.', pages.length + 1));
		pages.push(state);
	}
	return pages;
};

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
				paddingHorizontal: 4,
				minHeight: 48,
				backgroundColor: theme.backgroundColor,
				borderBottomWidth: StyleSheet.hairlineWidth,
				borderBottomColor: theme.dividerColor,
				gap: 2,
			},
			titleInput: {
				flex: 1,
				color: theme.color,
				fontSize: theme.fontSize,
				fontWeight: '600',
				paddingHorizontal: 8,
				paddingVertical: 6,
			},
			icon: {
				color: theme.color,
				fontSize: 22,
			},
			iconButton: {
				padding: 8,
			},
			canvas: {
				flex: 1,
			},
			overlay: {
				position: 'absolute', top: 0, left: 0, right: 0, bottom: 0,
				alignItems: 'center',
				justifyContent: 'center',
			},
		});
	}, [themeId]);
};

const CanvasNoteEditor: React.FC<Props> = props => {
	const CanvasView = useMemo(() => getNativeCanvasView(), []);
	const canvasRef = useRef<JoplinCanvasViewMethods|null>(null);
	const dialogs = useContext(DialogContext);
	const styles = useStyles(props.themeId);
	const theme = themeStyle(props.themeId);
	const darkMode = theme.appearance === ThemeAppearance.Dark;

	const [nativeViewReady, setNativeViewReady] = useState(false);
	const [loaded, setLoaded] = useState(false);
	const [busy, setBusy] = useState(false);
	const [title, setTitle] = useState(props.noteTitle);
	useEffect(() => {
		setTitle(props.noteTitle);
	}, [props.noteTitle]);
	const [viewState, setViewState] = useState<CanvasViewState>({ pageCount: 1, currentPage: 0, template: 'blank' });

	const propsRef = useRef(props);
	propsRef.current = props;

	// Pages that already exist as resources
	const savedPageIdsRef = useRef(new Set<string>());
	const lastBodyRef = useRef(props.noteBody);

	// Load
	useEffect(() => {
		if (!nativeViewReady) return () => {};
		let cancelled = false;

		const load = async () => {
			try {
				const pages = await loadPageStates(propsRef.current.noteBody);
				if (cancelled) return;
				savedPageIdsRef.current = new Set(pages.map(page => page.id));
				await canvasRef.current.loadPages(JSON.stringify(pages), propsRef.current.initialPageId);
				if (cancelled) return;
				setLoaded(true);
				void canvasRef.current.showToolPicker();
			} catch (error) {
				if (cancelled) return;
				logger.error('Failed to load canvas note', error);
				// Never risk overwriting pages that could not be loaded
				Alert.alert(_('Error'), _('The canvas note could not be opened: %s', error?.message ?? String(error)));
				propsRef.current.onExit();
			}
		};
		void load();

		return () => {
			cancelled = true;
		};
	}, [nativeViewReady]);

	// Saving: writes changed pages to resources and updates the note body.
	// Saves are queued so that they never run concurrently.
	const saveQueueRef = useRef<Promise<void>>(Promise.resolve());
	const saveNow = useCallback((recognizeText: boolean) => {
		const save = async () => {
			if (!canvasRef.current) return;
			const pages: CanvasPageExport[] = JSON.parse(await canvasRef.current.exportPages({ recognizeText }));

			try {
				for (const page of pages) {
					if (!page.changed || !page.state || !page.renderPngBase64) continue;

					const svg = buildCanvasPageSvg(page.renderPngBase64, page.state);
					const tempPath = join(Setting.value('tempDir'), `${page.id}.svg`);
					await shim.fsDriver().writeFile(tempPath, svg, 'utf8');
					try {
						if (savedPageIdsRef.current.has(page.id)) {
							await Resource.updateResourceBlobContent(page.id, tempPath);
						} else {
							await shim.createResourceFromPath(tempPath, { id: page.id, title: _('Canvas page'), mime: 'image/svg+xml' });
							savedPageIdsRef.current.add(page.id);
						}
					} finally {
						await shim.fsDriver().remove(tempPath);
					}

					if (typeof page.ocrText === 'string') {
						await saveDrawingOcrText(page.id, page.ocrText);
					}
				}
			} catch (error) {
				// Try again with the next save
				await canvasRef.current?.markAllUnsaved();
				throw error;
			}

			const body = buildCanvasNoteBody(pages, pageLabel);
			if (body !== lastBodyRef.current) {
				lastBodyRef.current = body;
				await propsRef.current.onBodyChange(body);
			}
		};

		const previous = saveQueueRef.current;
		const result = (async () => {
			await previous;
			await save();
		})();
		saveQueueRef.current = (async () => {
			try {
				await result;
			} catch (error) {
				logger.error('Failed to save canvas note', error);
			}
		})();
		return result;
	}, []);

	const autosaveTimeoutRef = useRef<ReturnType<typeof setTimeout>|null>(null);
	const onChanged = useCallback(() => {
		if (autosaveTimeoutRef.current) clearTimeout(autosaveTimeoutRef.current);
		autosaveTimeoutRef.current = setTimeout(() => {
			autosaveTimeoutRef.current = null;
			void saveNow(false);
		}, autosaveDelayMs);
	}, [saveNow]);

	useEffect(() => {
		const subscription = AppState.addEventListener('change', state => {
			if (state !== 'active' && loaded) void saveNow(false);
		});
		return () => {
			subscription.remove();
			if (autosaveTimeoutRef.current) clearTimeout(autosaveTimeoutRef.current);
		};
	}, [saveNow, loaded]);

	const onDone = useCallback(async () => {
		if (busy) return;
		setBusy(true);
		if (autosaveTimeoutRef.current) clearTimeout(autosaveTimeoutRef.current);
		try {
			await saveNow(true);
			propsRef.current.onExit();
		} catch (error) {
			setBusy(false);
			dialogs.prompt(_('Error'), _('The canvas note could not be saved: %s', error?.message ?? String(error)));
		}
	}, [busy, saveNow, dialogs]);

	useEffect(() => {
		const listener = () => {
			void onDone();
			return true;
		};
		BackButtonService.addHandler(listener);
		return () => BackButtonService.removeHandler(listener);
	}, [onDone]);

	const onTitleChange = useCallback((value: string) => {
		setTitle(value);
		propsRef.current.onTitleChange(value);
	}, []);

	const onStateChanged = useCallback((event: { nativeEvent: CanvasViewState }) => {
		setViewState(event.nativeEvent);
	}, []);

	const onPaperPress = useCallback(async () => {
		const template = await dialogs.showMenu<CanvasPaperTemplate>(_('Paper'), [
			{ id: 'blank', text: _('Blank'), checked: viewState.template === 'blank' },
			{ id: 'lined', text: _('Lined'), checked: viewState.template === 'lined' },
			{ id: 'grid', text: _('Grid'), checked: viewState.template === 'grid' },
		]);
		if (template) await canvasRef.current?.setTemplate(template);
	}, [dialogs, viewState.template]);

	const onMorePress = useCallback(async () => {
		type Action = 'pdf'|'deletePage';
		const choices = [{ id: 'pdf' as Action, text: _('Share as PDF') }];
		if (viewState.pageCount > 1) {
			choices.push({ id: 'deletePage', text: _('Delete page %d', viewState.currentPage + 1) });
		}

		const action = await dialogs.showMenu<Action>(_('Page %d of %d', viewState.currentPage + 1, viewState.pageCount), choices);
		try {
			if (action === 'pdf') {
				// Wait until the menu is closed, the share sheet can only be presented afterwards
				await msleep(500);
				await canvasRef.current?.sharePdf(title || _('Canvas note'));
			} else if (action === 'deletePage') {
				dialogs.prompt(_('Delete page %d?', viewState.currentPage + 1), _('This cannot be undone.'), [
					{ text: _('Delete'), onPress: () => void canvasRef.current?.deleteCurrentPage(), style: 'destructive' },
					{ text: _('Cancel'), style: 'cancel' },
				]);
			}
		} catch (error) {
			dialogs.prompt(_('Error'), error?.message ?? String(error));
		}
	}, [dialogs, title, viewState]);

	const renderIconButton = (iconName: string, description: string, onPress: ()=> void) => {
		return <IconButton
			themeId={props.themeId}
			iconName={iconName}
			description={description}
			onPress={onPress}
			disabled={!loaded || busy}
			iconStyle={styles.icon}
			contentWrapperStyle={styles.iconButton}
		/>;
	};

	return (
		<View style={styles.container}>
			<View style={styles.toolbar}>
				<TextButton type={ButtonType.Link} onPress={() => { void onDone(); }} disabled={busy}>{_('Done')}</TextButton>
				<TextInput
					style={styles.titleInput}
					value={title}
					onChangeText={onTitleChange}
					placeholder={_('Add title')}
					placeholderTextColor={theme.colorFaded}
					accessibilityLabel={_('Title')}
					returnKeyType='done'
				/>
				{renderIconButton('material format-text', _('Add text box'), () => void canvasRef.current?.addTextBox())}
				{renderIconButton('material image-plus', _('Insert image'), () => void canvasRef.current?.insertImage())}
				{renderIconButton('material notebook-outline', _('Paper'), () => void onPaperPress())}
				{renderIconButton('material file-plus-outline', _('Add page'), () => void canvasRef.current?.addPage(null))}
				{renderIconButton('material dots-vertical', _('More'), () => void onMorePress())}
			</View>
			<View style={styles.canvas}>
				<CanvasView
					ref={canvasRef}
					style={styles.canvas}
					darkMode={darkMode}
					onReady={() => setNativeViewReady(true)}
					onChanged={onChanged}
					onStateChanged={onStateChanged}
				/>
				{(!loaded || busy) && <View style={[styles.overlay, { backgroundColor: loaded ? 'transparent' : theme.backgroundColor }]}>
					<ActivityIndicator size='large' color={theme.color} accessibilityLabel={busy ? _('Saving...') : _('Loading...')} />
				</View>}
			</View>
		</View>
	);
};

export default CanvasNoteEditor;
