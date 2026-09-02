// What this board has answered, in the page that answered it.
//
// TKT-852. He asked for it after the dashboard would not load for him and
// nothing could say whether requests were arriving at all, then chose where it
// should appear: "A logs panel inside the browser dashboard itself, so the log
// is read in the page rather than in the terminal."
//
// THE SECTION IS ONLY RENDERED WITH --show-logs, so this script finding nothing
// to attach to is the normal case rather than a failure. It returns quietly.
//
// WHAT IT CANNOT TELL YOU, and the panel says so on screen rather than only in
// the docs: these are requests that ARRIVED. A page that never reaches the
// server leaves nothing here, so an empty panel does not mean the board is
// broken - it means nothing got this far.
//
// Pure ASCII: t/16 asserts it, because a non-ASCII glyph in a live script
// reaches the browser double-encoded.

const logsSection = document.querySelector(".board--logs");
if (logsSection) {
  const logsList = logsSection.querySelector(".logs-lines");
  const logsNote = logsSection.querySelector(".logs-note");

  const statusClass = (status) => {
    if (status >= 500) return "is-error";
    if (status >= 400) return "is-refused";
    return "is-ok";
  };

  const line = (entry) => {
    const li = document.createElement("li");
    li.className = "logs-line " + statusClass(entry.status);

    const status = document.createElement("span");
    status.className = "logs-line__status";
    status.textContent = entry.status;
    li.appendChild(status);

    const path = document.createElement("span");
    path.className = "logs-line__path";
    path.textContent = entry.path;
    li.appendChild(path);

    return li;
  };

  const loadLogs = () =>
    fetch("/logs", { cache: "no-store" })
      .then((response) => {
        // 404 is the documented answer when the board was not started with
        // --show-logs. It should not be reachable from a page that rendered
        // this section, but saying which failure happened beats a generic one.
        if (response.status === 404) {
          throw new Error("This board is not keeping a record of its requests.");
        }
        if (!response.ok) {
          throw new Error("The request log could not be read.");
        }
        return response.json();
      })
      .then((entries) => {
        logsList.replaceChildren(...entries.slice().reverse().map(line));
        logsNote.textContent = entries.length
          ? entries.length +
            " most recent request(s) this board answered. Only requests that reached the server appear here."
          : "Nothing has reached this board yet.";
      })
      .catch((error) => {
        logsList.replaceChildren();
        logsNote.textContent = error.message;
      });

  loadLogs();
  window.setInterval(loadLogs, 5000);
}
