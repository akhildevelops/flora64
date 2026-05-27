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
    // ---- 1. Prepare data & sizes ----
    const count = files.length;
    const sizes = new Uint32Array(count);
    let totalData = 0;
    for (let i = 0; i < count; i++) {
      sizes[i] = files[i].data.byteLength;
      totalData += sizes[i];
    }

    // Output buffer: total input data + generous overhead.
    const outputSize = totalData + 4096;

    // Memory layout in WASM linear memory:
    //   [0           .. totalData)          – file data (concatenated)
    //   [totalData   .. totalData + 4*count) – sizes array (u32 per file)
    //   [outputOffset .. outputOffset + outputSize) – output buffer
    const sizesSize = count * 4;
    const outputOffset = totalData + sizesSize;
    const totalMemory = outputOffset + outputSize;

    // ---- 2. Instantiate WASM ----
    // The WASM module exports its own memory (no imports needed).
    // We allocate via memory.grow() after instantiation if needed.
    const instance = new WebAssembly.Instance(wasmModule);
    const wasmMemory = instance.exports.memory;
    const mergeFn = instance.exports.merge_geojson;

    // Grow memory if needed (single grow call, each page = 64 KB)
    const pageSize = 65536;
    const pagesNeeded = Math.ceil(totalMemory / pageSize);
    const currentPages = wasmMemory.buffer.byteLength / pageSize;
    if (pagesNeeded > currentPages) {
      wasmMemory.grow(pagesNeeded - currentPages);
    }

    // ---- 3. Copy file data into WASM memory ----
    // IMPORTANT: must re-fetch buffer after each grow() call
    const view = new Uint8Array(wasmMemory.buffer);
    let offset = 0;
    for (let i = 0; i < count; i++) {
      const fileBytes = new Uint8Array(files[i].data);
      view.set(fileBytes, offset);
      offset += fileBytes.byteLength;
    }

    // Write sizes array
    const sizesView = new Uint32Array(wasmMemory.buffer, totalData, count);
    sizesView.set(sizes);

    // ---- 4. Call WASM merge ----
    const resultLen = mergeFn(
      0,             // data_ptr  – start of concatenated file data
      totalData,     // sizes_ptr – address of u32 sizes array
      count,         // count
      outputOffset,  // output_ptr
      outputSize,    // output_len
    );

    if (resultLen === 0) {
      throw new Error('Merge failed — output buffer may be too small');
    }

    // ---- 5. Copy result into a fresh buffer and transfer back ----
    // Copy only the result bytes rather than transferring entire WASM memory.
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
