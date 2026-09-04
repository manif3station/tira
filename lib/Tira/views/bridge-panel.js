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

  const kindClass = (kind) => {
    if (kind === "settled") return "is-ok";
    if (kind === "violation") return "is-refused";
    return "";
  };

  const line = (entry) => {
    const item = document.createElement("li");
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

  const paintBridge = (entries) => {
    bridgeList.textContent = "";
    entries.forEach((entry) => bridgeList.appendChild(line(entry)));

    // The distinction the request panel also makes: nothing found is not the
    // same claim as nothing running.
    bridgeNote.textContent = entries.length
      ? "The last " + entries.length + " thing(s) police said about this board."
      : "Nothing on the bridge yet. Police announces here when it runs.";
  };

  const refreshBridge = () =>
    fetch("/bridge", { cache: "no-store" })
      .then((response) => (response.ok ? response.json() : []))
      .then((entries) => paintBridge(Array.isArray(entries) ? entries : []))
      .catch(() => {});

  refreshBridge();

  // Five seconds, the same cadence the request panel polls on: it follows new
  // lines rather than needing a reload, which is the third thing his report
  // asked for.
  setInterval(refreshBridge, 5000);
}
