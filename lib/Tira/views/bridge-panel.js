// What the board has found, in the page rather than in a terminal.
//
// TKT-916, his report 6799: "Where is the terminal log windows to display and
// tail last 100 lines of the violation logs?"
//
// THE ANSWER WAS THAT IT EXISTED FOR A DIFFERENT LOG. logs-panel.js and /logs
// are TKT-852's request panel - what reached the server - which is why that
// card's first job was to establish whether this view already existed. The
// place and the shape were settled; the source was missing.
//
// A HUNDRED LINES, newest last, which is his number and is a panel rather than
// a whole file. The route decides how many; this only renders what it is given,
// so the two cannot disagree about the limit.
//
// AND IT SAYS WHAT AN EMPTY PANEL MEANS, the way the request panel does: a
// board that has found nothing and a board whose police has never run look
// identical here, and the note is what tells them apart.
//
// Pure ASCII: t/16 asserts it, because a non-ASCII glyph in a live script
// reaches the browser double-encoded.

const bridgeSection = document.querySelector(".board--bridge");

if (bridgeSection) {
  const bridgeList = bridgeSection.querySelector(".bridge-lines");
  const bridgeNote = bridgeSection.querySelector(".bridge-note");
  const bridgeClear = bridgeSection.querySelector(".bridge-clear");

  // TKT-1020. refreshBridge still polls every five seconds, so this clears
  // the current rendering only - a "read it clean right now" control, not a
  // change to what the bridge itself has recorded.
  if (bridgeClear) {
    bridgeClear.addEventListener("click", () => {
      bridgeList.textContent = "";
      bridgeNote.textContent = "Cleared. Waiting for the next thing police says.";
    });
  }

  const kindClass = (kind) => {
    if (kind === "settled") return "is-ok";
    if (kind === "violation") return "is-refused";
    return "";
  };

  const line = (entry) => {
    const item = document.createElement("div");
    item.className = "bridge-line";
    const when = document.createElement("span");
    when.className = "bridge-when";
    when.textContent = (entry.at || "").replace("T", " ").slice(0, 19);

    const said = document.createElement("span");
    said.className = "bridge-said " + kindClass(entry.kind);
    said.textContent = entry.detail || "";

    item.appendChild(when);
    item.appendChild(said);
    return item;
  };

  const paintBridge = (payload) => {
    const entries = (payload && payload.entries) || [];

    // NEWEST FIRST, REVERSED HERE AND NOT AT THE ROUTE. His message 7283: "so
    // they are reverse order ... From new to old". /bridge is shared - the
    // terminal and tira.policy.bridge.logs read the same engine call, and t/541
    // exists because two readers of one log drift - so the page turns the list
    // round for the reader and the board goes on saying what it said.
    //
    // slice() first: reverse() mutates in place, and the array here is the one
    // the payload was parsed into.
    const newestFirst = entries.slice().reverse();

    // Where he had scrolled to, kept across the repaint. The panel redraws
    // every five seconds; without this, reading anything below the fold means
    // being pulled back to the top before finishing the line.
    const wasAt = bridgeList.scrollTop;
    bridgeList.textContent = "";
    newestFirst.forEach((entry) => bridgeList.appendChild(line(entry)));
    bridgeList.scrollTop = wasAt;

    // THREE STATES, NOT TWO. Until TKT-949 a board this could not resolve, a
    // store it could not read and a genuinely quiet bridge all printed the
    // same sentence, so the owner reported the panel as never working and the
    // panel could not tell him which it was. A failed read now says so.
    if (payload && payload.ok === false) {
      bridgeNote.textContent =
        "The bridge could not be read for this board" +
        (payload.error ? ": " + payload.error : ".");
      return;
    }

    // The distinction the request panel also makes: nothing found is not the
    // same claim as nothing running.
    bridgeNote.textContent = entries.length
      ? "The last " + entries.length + " thing(s) police said about this board."
      : "Nothing on the bridge yet. Police announces here when it runs.";
  };

  const refreshBridge = () =>
    fetch("/bridge", { cache: "no-store" })
      .then((response) =>
        response.ok
          ? response.json()
          : { ok: false, entries: [], error: "the board answered " + response.status }
      )
      // An older board still answers with a bare list; read either shape rather
      // than showing nothing against a server that has not been upgraded yet.
      .then((payload) =>
        paintBridge(Array.isArray(payload) ? { ok: true, entries: payload } : payload)
      )
      .catch((err) =>
        paintBridge({ ok: false, entries: [], error: String((err && err.message) || err) })
      );

  refreshBridge();

  // Five seconds, the same cadence the request panel polls on: it follows new
  // lines rather than needing a reload, which is the third thing his report
  // asked for.
  setInterval(refreshBridge, 5000);
}
