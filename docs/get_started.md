# Get started: from zero to a chat that guides you

You do this once per computer, in about 30 minutes, and **you never need to have used a command line**. After that, the
chat in VS Code does the work and tells you what to do. The same steps, in Hebrew and English, are on the start page:
https://avisalmon.github.io/De10LiteBKM/

**Before you start you need:** a Terasic DE10-Lite and its USB cable (the LCD / game-pad shield is optional for stage 1),
a Windows computer with about 20 GB free, and an email address for a free MyAltera account (the chat walks you through it).
*You know you are ready when* the board's LEDs light up when you plug it into the computer.

## 1. VS Code, the editor

VS Code is a program for writing code; the chat lives inside it. Download from https://code.visualstudio.com, run the
installer, click Next until it finishes. *You know it worked when* VS Code opens.

## 2. Git

Git copies projects from the internet to your computer and keeps them updated. Download from
https://git-scm.com/downloads, run it, click Next on every screen (the defaults are fine). Then close VS Code and open
it again.

## 3. An AI chat inside VS Code (pick one)

* **Claude Code**: in VS Code, click the four-squares icon on the side (Extensions) -> search "Claude Code" -> Install ->
  sign in with a Claude account (a paid plan is needed for long sessions).
* **GitHub Copilot**: needs a free GitHub account (https://github.com/signup). In VS Code, click the person icon at the
  bottom of the side bar, sign in to GitHub, open the Copilot chat and switch it to **Agent** mode.

*You know it worked when* you type `hello` in the chat and it answers.

## 4. Copy the project to your computer, with clicks only

1. In VS Code press **Ctrl+Shift+P**. A search box opens at the top.
2. Type **Git: Clone** and press Enter.
3. Paste `https://github.com/avisalmon/De10LiteBKM.git` and press Enter.
4. Choose a folder to keep it in (Documents is fine) and click **Select as Repository Destination**.
5. When the message appears at the bottom, click **Open**, then **Yes, I trust the authors**.

*You know it worked when* the project's files (README.md, CLAUDE.md...) show on the left.

### Or with the terminal (only if you prefer)

**What is a terminal?** A window where you give the computer instructions by typing instead of clicking. You type a
line, press Enter, and the computer does it.

**Open it in VS Code:** menu **Terminal -> New Terminal** (or **Ctrl+`**, the key under Esc). A panel opens at the
bottom with a line like `PS C:\Users\you>`. That line is the *prompt*: the computer waiting for you.

**Use it:** click inside the panel; paste one line with **Ctrl+V** or a right-click; press Enter; wait until the prompt
appears again (that means it finished). Red text is an error: copy it into the chat and it will explain.

```powershell
mkdir C:\bkm                          # make a folder called bkm
cd C:\bkm                             # go into it
git clone https://github.com/avisalmon/De10LiteBKM.git            # copy the project into it
code De10LiteBKM                    # open it in VS Code
```

## 5. Say it

Open the AI chat in that window and type:

> **תגיד לי מה לעשות** (or: **Tell me what to do**)

From here the chat installs what is missing and does the work with you. **You don't type commands any more**: the chat
runs them itself, and before each one shows what it wants to run and asks you to allow it. Not sure? Ask the chat
"what does this command do?"

## Words you'll meet

| Word | Means |
|---|---|
| Repository (repo) | a project folder with its whole history, kept on GitHub |
| Clone | copy a repository to your computer |
| Terminal / command line | a window where you type instructions instead of clicking |
| Prompt | the line in the terminal that says the computer is waiting for you |
| Pull updates | get the newest version of this guide from GitHub (the chat does it every session) |
| FPGA | a chip whose logic you design yourself; here an Intel / Altera MAX 10 |
| Verilog | the language you describe the hardware in |
| Quartus | Altera's tool that turns Verilog into a bitstream for the chip |
| .sof / .pof | the bitstream: .sof lasts until power-off, .pof goes into the chip's flash and stays |
| ModelSim | the simulator: runs your Verilog on the computer, with waveforms, no board needed |
| USB-Blaster | the USB link built into the board: programming and talking to the design |
