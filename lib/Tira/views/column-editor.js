const columnDialog = document.querySelector(".column-dialog");
const columnList = columnDialog.querySelector(".column-editor");
const columnError = columnDialog.querySelector(".column-dialog__error");
let columnType = "";
const columnFail = (message) => {
  columnError.textContent = message;
  columnError.hidden = false;
};
const columnRow = (column, allNames) => {
  allNames = allNames || [];
  const row = document.createElement("li");
  row.className = "column-row";
  row.dataset.name = column.name;
  if (column.protected) row.dataset.protected = "1";
  if (Array.isArray(column.next) && column.next.length)
    row.dataset.hadNext = "1";
  if (Array.isArray(column.required_actions) && column.required_actions.length)
    row.dataset.hadActions = "1";
  if (
    Array.isArray(column.administrative_actions) &&
    column.administrative_actions.length
  )
    row.dataset.hadAdministrativeActions = "1";
  const grip = document.createElement("span");
  grip.className = "column-row__grip";
  grip.setAttribute("aria-hidden", "true");
  grip.textContent = "\u2261";
  // TKT-772. row.dataset.name is deliberately never rewritten - it stays
  // the ORIGINAL name for this row's whole lifetime, which is what makes
  // it usable both as rename_from (the explicit signal column_apply now
  // requires, since guessing a rename from a layout's own shape was proven
  // unsound) and as the stable key other rows' own "Next" checkboxes were
  // built against. The name INPUT is the only thing the user edits.
  const name = document.createElement("input");
  name.className = "column-row__name";
  name.setAttribute("aria-label", "Column name");
  name.value = column.name;
  name.disabled = !!column.protected;
  if (column.protected) name.title = "A protected column cannot be renamed";
  const label = document.createElement("input");
  label.className = "column-row__label";
  label.setAttribute("aria-label", "Column label");
  label.value = column.label || column.name;
  const minutes = document.createElement("input");
  minutes.className = "column-row__minutes";
  minutes.type = "number";
  minutes.min = "1";
  minutes.placeholder = "none";
  minutes.setAttribute(
    "aria-label",
    "Minutes before a card here counts as stuck",
  );
  if (column.notify_after !== null && column.notify_after !== undefined)
    minutes.value = column.notify_after;
  const eye = document.createElement("button");
  eye.type = "button";
  eye.className = "column-row__eye";
  eye.title = "Send reminders about cards left in this column";
  const watched = column.watched === undefined ? true : !!column.watched;
  eye.setAttribute("aria-pressed", watched ? "true" : "false");
  eye.textContent = watched ? "\u25c9" : "\u25cb";
  eye.addEventListener("click", () => {
    const on = eye.getAttribute("aria-pressed") !== "true";
    eye.setAttribute("aria-pressed", on ? "true" : "false");
    eye.textContent = on ? "\u25c9" : "\u25cb";
  });
  const entryWrap = document.createElement("label");
  entryWrap.className = "column-row__entry-wrap";
  entryWrap.title = "New cards can start here";
  const entryBox = document.createElement("input");
  entryBox.type = "checkbox";
  entryBox.className = "column-row__entry";
  entryBox.checked = !!column.entry;
  entryWrap.append(entryBox, document.createTextNode("Entry"));
  row.append(grip, name, label, minutes, eye, entryWrap);
  const nextWrap = document.createElement("div");
  nextWrap.className = "column-row__next-wrap";
  const nextLabel = document.createElement("span");
  nextLabel.className = "column-row__next-label";
  nextLabel.textContent = "Next";
  const nextList = document.createElement("div");
  nextList.className = "column-row__next-list";
  allNames
    .filter((name) => name !== column.name)
    .forEach((name) => {
      const chip = document.createElement("label");
      chip.className = "column-row__next-chip";
      const checkbox = document.createElement("input");
      checkbox.type = "checkbox";
      checkbox.className = "column-row__next-checkbox";
      checkbox.value = name;
      checkbox.checked =
        Array.isArray(column.next) && column.next.includes(name);
      const chipText = document.createElement("span");
      chipText.textContent = name;
      chip.append(checkbox, chipText);
      nextList.append(chip);
    });
  nextWrap.append(nextLabel, nextList);
  row.append(nextWrap);
  const actionsWrap = document.createElement("div");
  actionsWrap.className = "column-row__actions-wrap";
  const actionsLabel = document.createElement("span");
  actionsLabel.className = "column-row__actions-label";
  actionsLabel.textContent = "Exit required actions";
  const actionsList = document.createElement("div");
  actionsList.className = "column-row__actions-list";
  const buildActionRow = (value, isBlank, inputClass) => {
    const kind =
      inputClass === "column-row__entry-action-input"
        ? "entry"
        : inputClass === "column-row__administrative-action-input"
          ? "administrative"
          : "exit";
    const rowClass = {
      entry: "column-row__entry-action-row",
      administrative: "column-row__administrative-action-row",
      exit: "",
    }[kind];
    const addClass = {
      entry: "column-row__entry-action-add",
      administrative: "column-row__administrative-action-add",
      exit: "column-row__action-add",
    }[kind];
    const removeClass = {
      entry: "column-row__entry-action-remove",
      administrative: "column-row__administrative-action-remove",
      exit: "column-row__action-remove",
    }[kind];
    const addPlaceholder = {
      entry: "Add an entry required action",
      administrative: "Add an administrative action",
      exit: "Add an exit required action",
    }[kind];
    const noun = {
      entry: "Entry required action",
      administrative: "Administrative action",
      exit: "Exit required action",
    }[kind];
    const actionRow = document.createElement("div");
    actionRow.className = rowClass
      ? "column-row__action-row " + rowClass
      : "column-row__action-row";
    if (!isBlank) {
      const actionGrip = document.createElement("span");
      actionGrip.className = "column-row__action-grip";
      actionGrip.setAttribute("aria-hidden", "true");
      actionGrip.textContent = "\u2261";
      actionRow.append(actionGrip);
    }
    const input = document.createElement("input");
    input.type = "text";
    input.className = inputClass || "column-row__action-input";
    input.value = value || "";
    input.placeholder = isBlank ? addPlaceholder + "\u2026" : "";
    input.setAttribute("aria-label", isBlank ? addPlaceholder : noun);
    const btn = document.createElement("button");
    btn.type = "button";
    if (isBlank) {
      btn.className = addClass;
      btn.textContent = "\u2713";
      btn.setAttribute("aria-label", "Add this required action");
      btn.addEventListener("click", () => {
        const text = input.value.trim();
        if (!text) return;
        actionRow.parentElement.insertBefore(
          buildActionRow(text, false, inputClass),
          actionRow,
        );
        input.value = "";
      });
    } else {
      btn.className = removeClass;
      btn.textContent = "\u00d7";
      btn.setAttribute("aria-label", "Remove this required action");
      btn.addEventListener("click", () => actionRow.remove());
    }
    actionRow.append(input, btn);
    return actionRow;
  };
  (Array.isArray(column.required_actions)
    ? column.required_actions
    : []
  ).forEach((item) =>
    actionsList.append(buildActionRow(item, false, "column-row__action-input")),
  );
  actionsList.append(buildActionRow("", true, "column-row__action-input"));
  actionsWrap.append(actionsLabel, actionsList);
  const entryActionsWrap = document.createElement("div");
  entryActionsWrap.className = "column-row__actions-wrap";
  const entryActionsLabel = document.createElement("span");
  entryActionsLabel.className = "column-row__actions-label";
  entryActionsLabel.textContent = "Entry required actions";
  entryActionsLabel.title =
    "What a card must already have done before it may be moved INTO this column";
  const entryActionsList = document.createElement("div");
  entryActionsList.className = "column-row__entry-actions-list";
  if (
    Array.isArray(column.entry_required_actions) &&
    column.entry_required_actions.length
  )
    row.dataset.hadEntryActions = "1";
  (Array.isArray(column.entry_required_actions)
    ? column.entry_required_actions
    : []
  ).forEach((item) =>
    entryActionsList.append(
      buildActionRow(item, false, "column-row__entry-action-input"),
    ),
  );
  entryActionsList.append(
    buildActionRow("", true, "column-row__entry-action-input"),
  );
  entryActionsWrap.append(entryActionsLabel, entryActionsList);
  const administrativeActionsWrap = document.createElement("div");
  administrativeActionsWrap.className = "column-row__actions-wrap";
  const administrativeActionsLabel = document.createElement("span");
  administrativeActionsLabel.className = "column-row__actions-label";
  administrativeActionsLabel.textContent = "Administrative actions";
  administrativeActionsLabel.title =
    "Required-action items, by exact text, that a backward move never resets";
  const administrativeActionsList = document.createElement("div");
  administrativeActionsList.className =
    "column-row__administrative-actions-list";
  (Array.isArray(column.administrative_actions)
    ? column.administrative_actions
    : []
  ).forEach((item) =>
    administrativeActionsList.append(
      buildActionRow(item, false, "column-row__administrative-action-input"),
    ),
  );
  administrativeActionsList.append(
    buildActionRow("", true, "column-row__administrative-action-input"),
  );
  administrativeActionsWrap.append(
    administrativeActionsLabel,
    administrativeActionsList,
  );
  row.append(entryActionsWrap, actionsWrap, administrativeActionsWrap);
  if (!column.protected) {
    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "column-row__remove";
    remove.textContent = "\u00d7";
    remove.setAttribute("aria-label", "Remove this column");
    remove.title = "Remove this column. Any cards in it go to Discard.";
    remove.addEventListener("click", () => row.remove());
    row.append(remove);
  }
  return row;
};
// TKT-772. A "Next" checkbox's own value is the ORIGINAL name of the column
// it targets - fixed once, when the dialog opened, from the layout as it
// stood then. If that column has since been renamed in this same editing
// session, the checkbox still says the old name; this maps it forward to
// whatever that row's name input currently holds, so a saved "next" entry
// names the column the caller will actually get, not the one that stopped
// existing the moment the rename is applied.
const currentNameOf = (originalName) => {
  const row = Array.from(columnList.querySelectorAll(".column-row")).find(
    (r) => r.dataset.name === originalName,
  );
  if (!row) return originalName;
  const input = row.querySelector(".column-row__name");
  return (input && input.value.trim()) || row.dataset.name;
};
const columnLayout = () =>
  Array.from(columnList.querySelectorAll(".column-row")).map((row) => {
    const minutes = row.querySelector(".column-row__minutes").value.trim();
    const currentName =
      row.querySelector(".column-row__name").value.trim() || row.dataset.name;
    const entry = {
      name: currentName,
      label:
        row.querySelector(".column-row__label").value.trim() || currentName,
      watched:
        row.querySelector(".column-row__eye").getAttribute("aria-pressed") ===
        "true"
          ? 1
          : 0,
    };
    // Sent ONLY when the name actually changed - column_apply trusts this
    // field exactly because nothing else ever sets it, so an unrenamed row
    // must never carry it, not even as an unchanged echo of its own name.
    if (currentName !== row.dataset.name) entry.rename_from = row.dataset.name;
    if (minutes !== "") entry.notify_after = Number(minutes);
    const nextVals = Array.from(
      row.querySelectorAll(".column-row__next-checkbox:checked"),
    ).map((c) => currentNameOf(c.value));
    if (nextVals.length || row.dataset.hadNext === "1") entry.next = nextVals;
    const actionLines = Array.from(
      row.querySelectorAll(".column-row__action-input"),
    )
      .map((i) => i.value.trim())
      .filter(Boolean);
    if (actionLines.length || row.dataset.hadActions === "1")
      entry.required_actions = actionLines;
    const entryActionLines = Array.from(
      row.querySelectorAll(".column-row__entry-action-input"),
    )
      .map((i) => i.value.trim())
      .filter(Boolean);
    if (entryActionLines.length || row.dataset.hadEntryActions === "1")
      entry.entry_required_actions = entryActionLines;
    const administrativeActionLines = Array.from(
      row.querySelectorAll(".column-row__administrative-action-input"),
    )
      .map((i) => i.value.trim())
      .filter(Boolean);
    if (
      administrativeActionLines.length ||
      row.dataset.hadAdministrativeActions === "1"
    )
      entry.administrative_actions = administrativeActionLines;
    return entry;
  });
const entryLayout = () =>
  Array.from(columnList.querySelectorAll(".column-row"))
    .filter((row) => row.querySelector(".column-row__entry").checked)
    .map(
      (row) =>
        row.querySelector(".column-row__name").value.trim() ||
        row.dataset.name,
    );
const openColumns = (type) => {
  columnType = type;
  columnError.hidden = true;
  columnList.textContent = "";
  columnDialog.showModal();
  return fetch("/columns?type=" + encodeURIComponent(type), {
    cache: "no-store",
  })
    .then((response) => {
      if (!response.ok) throw new Error("columns failed");
      return response.json();
    })
    .then((list) => {
      const allNames = list.map((column) => column.name);
      list.forEach((column) => columnList.append(columnRow(column, allNames)));
    })
    .catch(() => columnFail("Could not read the columns."));
};
const saveColumns = () =>
  fetch("/columns/apply", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      type: columnType,
      columns: columnLayout(),
      entry: entryLayout(),
    }),
  })
    .then((response) =>
      response.json().then((body) => ({ ok: response.ok, body })),
    )
    .then((result) => {
      if (!result.ok || result.body.error) {
        columnFail(result.body.error || "Could not save the columns.");
        return;
      }
      columnDialog.close();
      location.reload();
    })
    .catch(() => columnFail("Could not save the columns."));
const addColumn = () => {
  const field = columnDialog.querySelector(".column-dialog__new");
  const text = field.value.trim();
  if (text === "") return;
  const slug = text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  if (slug === "") {
    columnFail("That name has no letters or digits in it.");
    return;
  }
  const rows = columnList.querySelectorAll(".column-row");
  // Checked against each row's CURRENT name, not its original data-name - a
  // row renamed earlier in this same editing session (mid -> new) still
  // carries data-name="mid", so a lookup keyed on that would miss a second
  // row now trying to claim "new" and let the layout leave with two columns
  // of the same final name, refused only once it reaches the server.
  const liveNames = Array.from(rows).map(
    (r) => (r.querySelector(".column-row__name").value || "").trim() || r.dataset.name,
  );
  if (liveNames.includes(slug)) {
    columnFail("This board already has a column called " + slug + ".");
    return;
  }
  columnError.hidden = true;
  const last = rows[rows.length - 1];
  const allNames = liveNames;
  const row = columnRow({ name: slug, label: text, watched: 1 }, allNames);
  if (last && last.dataset.protected) columnList.insertBefore(row, last);
  else columnList.append(row);
  field.value = "";
};
let columnDragged = null;
const columnDragMove = (event) => {
  if (!columnDragged) return;
  event.preventDefault();
  const over = Array.from(columnList.querySelectorAll(".column-row")).find(
    (row) => {
      if (row === columnDragged) return false;
      const box = row.getBoundingClientRect();
      return event.clientY >= box.top && event.clientY <= box.bottom;
    },
  );
  if (!over) return;
  const box = over.getBoundingClientRect();
  columnList.insertBefore(
    columnDragged,
    event.clientY > box.top + box.height / 2 ? over.nextSibling : over,
  );
};
const columnDragEnd = () => {
  if (columnDragged) columnDragged.classList.remove("is-dragging");
  columnDragged = null;
  window.removeEventListener("pointermove", columnDragMove, { passive: false });
  window.removeEventListener("pointerup", columnDragEnd);
};
columnList.addEventListener("pointerdown", (event) => {
  const grip = event.target.closest(".column-row__grip");
  if (!grip) return;
  event.preventDefault();
  columnDragged = grip.closest(".column-row");
  if (!columnDragged) return;
  columnDragged.classList.add("is-dragging");
  window.addEventListener("pointermove", columnDragMove, { passive: false });
  window.addEventListener("pointerup", columnDragEnd);
});
let actionDragged = null;
const actionDragMove = (event) => {
  if (!actionDragged) return;
  event.preventDefault();
  const list = actionDragged.parentElement;
  if (!list) return;
  const over = Array.from(
    list.querySelectorAll(".column-row__action-row"),
  ).find((row) => {
    if (
      row === actionDragged ||
      row.querySelector(
        ".column-row__action-add,.column-row__entry-action-add,.column-row__administrative-action-add",
      )
    )
      return false;
    const box = row.getBoundingClientRect();
    return event.clientY >= box.top && event.clientY <= box.bottom;
  });
  if (!over) return;
  const box = over.getBoundingClientRect();
  list.insertBefore(
    actionDragged,
    event.clientY > box.top + box.height / 2 ? over.nextSibling : over,
  );
};
const actionDragEnd = () => {
  if (actionDragged) actionDragged.classList.remove("is-dragging");
  actionDragged = null;
  window.removeEventListener("pointermove", actionDragMove, { passive: false });
  window.removeEventListener("pointerup", actionDragEnd);
};
columnList.addEventListener("pointerdown", (event) => {
  const actionGrip = event.target.closest(".column-row__action-grip");
  if (!actionGrip) return;
  event.preventDefault();
  actionDragged = actionGrip.closest(".column-row__action-row");
  if (!actionDragged) return;
  actionDragged.classList.add("is-dragging");
  window.addEventListener("pointermove", actionDragMove, { passive: false });
  window.addEventListener("pointerup", actionDragEnd);
});
columnDialog
  .querySelector(".column-dialog__save")
  .addEventListener("click", saveColumns);
columnDialog
  .querySelector(".column-dialog__cancel")
  .addEventListener("click", () => columnDialog.close());
columnDialog
  .querySelector(".column-dialog__close")
  .addEventListener("click", () => columnDialog.close());
columnDialog
  .querySelector(".column-dialog__addbtn")
  .addEventListener("click", addColumn);
document
  .querySelectorAll("[data-columns]")
  .forEach((button) =>
    button.addEventListener("click", () => openColumns(button.dataset.columns)),
  );
window.tiraColumns = {
  open: openColumns,
  save: saveColumns,
  add: addColumn,
  layout: columnLayout,
  entryLayout: entryLayout,
};
