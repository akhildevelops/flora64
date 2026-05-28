// ----------------------------------------------------------------
// merge.worker.js — Off-main-thread GeoJSON merge via Zig WASM
//
// Receives: { type: 'merge', wasmModule, files: [{name, data: ArrayBuffer}] }
// Responds: { type: 'complete', data: ArrayBuffer, totalBytes, totalFeatures }
//           { type: 'error', error: string }
// ----------------------------------------------------------------

self.onmessage = function (e) {
  const { type, wasmModule, files } = e.data;
  if (type !== 'merge') return;

  try {
    // ---- 1. Instantiate WASM first, read its memory layout ----
    const instance = new WebAssembly.Instance(wasmModule);
    const wasmMemory = instance.exports.memory;
    const mergeFn = instance.exports.merge_geojson;

    // IMPORTANT: The WASM module's initial pages contain its internal data
    // (stack, globals, BSS).  We must NOT write file data at offset 0,
    // or we'll corrupt the module's internals.
    const dataOffset = wasmMemory.buffer.byteLength;

    // ---- 2. Prepare data & sizes ----
    const count = files.length;
    const sizes = new Uint32Array(count);
    let totalData = 0;
    for (let i = 0; i < count; i++) {
      sizes[i] = files[i].data.byteLength;
      totalData += sizes[i];
    }

    // Output buffer: 2x input data to safely account for comma/\n separators
    // between features (each extracted feature adds a 2-byte separator).
    const outputSize = totalData * 2 + 65536;

    // Memory layout in WASM linear memory (all offsets 4-byte aligned):
    //   [0                 .. dataOffset)                   – reserved (WASM internals)
    //   [dataOffset        .. dataOffset + totalData)       – file data (concatenated)
    //   [alignedSizesStart .. alignedSizesStart + 4*count)  – sizes array (u32 per file)
    //   [outputOffset      .. outputOffset + outputSize)    – output buffer
    const dataEnd = dataOffset + totalData;
    const alignedSizesStart = Math.ceil(dataEnd / 4) * 4;
    const sizesSize = count * 4;
    const outputOffset = alignedSizesStart + sizesSize;
    const totalMemory = outputOffset + outputSize;

    // ---- 3. Grow memory if needed (single grow call) ----
    const pageSize = 65536;
    const pagesNeeded = Math.ceil(totalMemory / pageSize);
    const currentPages = wasmMemory.buffer.byteLength / pageSize;
    if (pagesNeeded > currentPages) {
      wasmMemory.grow(pagesNeeded - currentPages);
    }

    // ---- 4. Copy file data into WASM memory ----
    const view = new Uint8Array(wasmMemory.buffer);
    let offset = dataOffset;
    for (let i = 0; i < count; i++) {
      const fileBytes = new Uint8Array(files[i].data);
      view.set(fileBytes, offset);
      offset += fileBytes.byteLength;
    }

    // Write sizes array at aligned offset
    const sizesView = new Uint32Array(wasmMemory.buffer, alignedSizesStart, count);
    sizesView.set(sizes);

    // ---- 5. Call WASM merge ----
    const resultLen = mergeFn(
      dataOffset,          // data_ptr  – start of concatenated file data
      alignedSizesStart,   // sizes_ptr – address of u32 sizes array
      count,               // count
      outputOffset,        // output_ptr
      outputSize,          // output_len
    );

    if (resultLen === 0) {
      throw new Error('Merge failed: returned 0 bytes. The output may be too large.');
    }

    // ---- 6. Copy result into a fresh buffer and transfer back ----
    const resultBytes = new Uint8Array(resultLen);
    resultBytes.set(new Uint8Array(wasmMemory.buffer, outputOffset, resultLen));

    self.postMessage(
      {
        type: 'complete',
        data: resultBytes.buffer,
        fileCount: count,
        totalBytes: resultLen,
      },
      [resultBytes.buffer],
    );
  } catch (err) {
    self.postMessage({ type: 'error', error: err.message || String(err) });
  }
};
