const PNG = Buffer.from('89504e470d0a1a0a', 'hex');
const finite = Number.isFinite;
export const validRect = rect => rect && [rect.x, rect.y, rect.width, rect.height].every(finite) && rect.width > 0 && rect.height > 0;

/** Use the delivered PNG dimensions, including independent rounding on each axis. */
export function normalizeScreenshot(shot) {
  const bad = () => { throw new Error('Invalid screenshot geometry. Reobserve the window; no coordinate input can be sent.'); };
  const png = Buffer.from(shot.base64, 'base64');
  if (png.length < 33 || !png.subarray(0, 8).equals(PNG) || png.toString('ascii', 12, 16) !== 'IHDR') bad();
  const width = png.readUInt32BE(16), height = png.readUInt32BE(20);
  if (!width || !height || !validRect(shot.bounds)) bad();
  if ((shot.width !== undefined && shot.width !== width) || (shot.height !== undefined && shot.height !== height)) bad();
  if (shot.imageScale !== undefined && (!finite(shot.imageScale) || shot.imageScale <= 0)) bad();
  // Older unscaled captures omit origin/imageScale; bounds still contain their
  // physical origin. Never treat malformed explicit geometry as a default.
  const origin = shot.origin === undefined ? { x: shot.bounds.x, y: shot.bounds.y } : shot.origin;
  if (!origin || !finite(origin.x) || !finite(origin.y) || origin.x !== shot.bounds.x || origin.y !== shot.bounds.y) bad();
  return { ...shot, width, height, origin, scaleX: width / shot.bounds.width, scaleY: height / shot.bounds.height };
}
