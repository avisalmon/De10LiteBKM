// DE10-Lite course: the lesson slides in a VS Code tab, opened and turned by the chat
//
// The chat writes my_designs/lessons/show.json, e.g. {"lesson": 1, "slide": 5, "at": "..."}
// (scripts/lesson.py open 1 5 does exactly that), and this extension, in the VS Code window that has the course
// open, shows lessons/NN_name/index.html in a tab at that slide. The slide the student is on goes back to
// my_designs/lessons/slides.json, so the chat knows it. (A vscode:// link was tried first: Windows hands it to
// whichever VS Code window it likes, so a file watched by the right window is more reliable.)
// ***********************************************

const vscode = require("vscode");
const fs = require("fs");
const path = require("path");

let panel = null;
let shownDir = null;

function courseRoot() {
	for (const folder of vscode.workspace.workspaceFolders || []) {
		let dir = folder.uri.fsPath;
		for (let i = 0; i < 6; i++) {
			if (fs.existsSync(path.join(dir, "lessons")) && fs.existsSync(path.join(dir, "scripts", "lesson.py"))) return dir;
			const up = path.dirname(dir);
			if (up === dir) break;
			dir = up;
		}
	}
	return null;
}

function lessonDir(root, lesson) {
	const prefix = String(parseInt(lesson, 10)).padStart(2, "0") + "_";
	const found = fs.readdirSync(path.join(root, "lessons")).find((d) => d.startsWith(prefix));
	return found ? path.join(root, "lessons", found) : null;
}

// The page as it is, plus: relative links resolve inside the lesson folder, it opens at the asked slide, and it
// reports the slide it is on. Inside a webview the page's #slide address does not work, so this drives the deck
// through its own slide dots (#dots buttons; the lit one has the class "cur"), which every lesson page has.
function pageHtml(webview, dir, slide) {
	const base = webview.asWebviewUri(vscode.Uri.file(dir)).toString() + "/";
	let html = fs.readFileSync(path.join(dir, "index.html"), "utf8");
	const bridge = `<script>
		(function () {
			var vscode = acquireVsCodeApi(), last = -1;
			function dots() { return document.querySelectorAll("#dots button"); }
			function goTo(n) { var d = dots()[n - 1]; if (d) d.click(); }
			window.addEventListener("message", function (e) { if (e.data && e.data.slide) goTo(e.data.slide); });
			setInterval(function () {
				var d = dots(), cur = -1;
				for (var i = 0; i < d.length; i++) if (d[i].classList.contains("cur")) cur = i + 1;
				if (cur > 0 && cur !== last) { last = cur; vscode.postMessage({ slide: cur }); }
			}, 300);
			${slide ? `setTimeout(function () { goTo(${parseInt(slide, 10)}); }, 0);` : ""}
		})();
	</script>`;
	html = html.replace(/<head>/i, `<head><base href="${base}">`);
	html = html.replace(/<\/body>/i, `${bridge}</body>`);
	return html;
}

function show(lesson, slide) {
	const root = courseRoot();
	if (!root) return vscode.window.showErrorMessage("DE10 course: open the course folder in VS Code first.");
	const dir = lessonDir(root, lesson);
	if (!dir) return vscode.window.showErrorMessage(`DE10 course: there is no lesson ${lesson}.`);

	if (panel && shownDir === dir) {
		panel.reveal(vscode.ViewColumn.One, false);
		if (slide) panel.webview.postMessage({ slide: parseInt(slide, 10) });
		return;
	}
	if (!panel) {
		panel = vscode.window.createWebviewPanel("de10course", "Lesson", vscode.ViewColumn.One,
			{ enableScripts: true, retainContextWhenHidden: true, localResourceRoots: [vscode.Uri.file(path.join(root, "lessons"))] });
		panel.onDidDispose(() => { panel = null; shownDir = null; });
		panel.webview.onDidReceiveMessage((m) => {
			if (!m || !m.slide || !shownDir) return;
			const out = path.join(root, "my_designs", "lessons");
			fs.mkdirSync(out, { recursive: true });
			fs.writeFileSync(path.join(out, "slides.json"),
				JSON.stringify({ lesson: path.basename(shownDir), slide: m.slide, at: new Date().toISOString() }, null, 2) + "\n");
		});
	}
	shownDir = dir;
	panel.title = "Lesson " + parseInt(lesson, 10);
	panel.webview.html = pageHtml(panel.webview, dir, slide);
	panel.reveal(vscode.ViewColumn.One, false);
}

function activate(context) {
	const root = courseRoot();
	if (root) {
		const requests = path.join(root, "my_designs", "lessons", "show.json");
		const log = vscode.window.createOutputChannel("DE10 Course");
		context.subscriptions.push(log);
		let lastSeen = "";
		const handle = () => {
			let text;
			try { text = fs.readFileSync(requests, "utf8"); } catch (e) { return; }		// deleted
			if (text === lastSeen) return;													// one request, two events
			lastSeen = text;
			try {
				const r = JSON.parse(text);
				log.appendLine(`show lesson ${r.lesson} slide ${r.slide}`);
				show(r.lesson, r.slide);
			} catch (e) { log.appendLine("request failed: " + e); lastSeen = ""; }
		};
		// VS Code's watcher, and Node's on the folder as well (VS Code's misses files written from outside on
		// some machines); whichever fires first wins, the other sees the same text and returns
		const watcher = vscode.workspace.createFileSystemWatcher(
			new vscode.RelativePattern(vscode.Uri.file(root), "my_designs/lessons/show.json"));
		watcher.onDidCreate(handle);
		watcher.onDidChange(handle);
		context.subscriptions.push(watcher);
		const folder = path.dirname(requests);
		fs.mkdirSync(folder, { recursive: true });
		const nodeWatcher = fs.watch(folder, (event, name) => { if (name === "show.json") setTimeout(handle, 50); });
		context.subscriptions.push({ dispose: () => nodeWatcher.close() });
		log.appendLine("watching " + requests);
	}
	context.subscriptions.push(vscode.commands.registerCommand("de10course.show", async (lesson, slide) => {
		if (lesson === undefined) lesson = await vscode.window.showInputBox({ prompt: "Lesson number", value: "0" });
		if (lesson !== undefined) show(lesson, slide);
	}));
}

function deactivate() {}

module.exports = { activate, deactivate };
