import Resource from '@joplin/lib/models/Resource';
import { ResourceOcrDriverId, ResourceOcrStatus } from '@joplin/lib/services/database/types';

// Keeps the synchronised item small
const maxOcrTextLength = 100000;

// Stores text recognised on the device in the drawing's resource.
//
// - `ocr_*` fields are part of the synchronised resource, so the text reaches
//   all other clients.
// - The search engine indexes `ocr_text` of resources with status "Done" and
//   returns the notes that link to them.
// - The desktop OcrService only processes resources with status "Todo" and a
//   supported (raster/PDF) mime type, so it never re-processes or overwrites
//   this result.
const saveDrawingOcrText = async (resourceId: string, text: string) => {
	await Resource.save({
		id: resourceId,
		ocr_text: text.substring(0, maxOcrTextLength),
		ocr_status: ResourceOcrStatus.Done,
		ocr_driver_id: ResourceOcrDriverId.HandwrittenText,
		ocr_error: '',
		ocr_details: '',
	});
};

export default saveDrawingOcrText;
