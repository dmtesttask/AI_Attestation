import os
import time
import zipfile
import xml.etree.ElementTree as ET
import re
import shutil

WATCH_DIR = "/home/openclaw/.openclaw/media/inbound"
DEST_DIR = "/home/openclaw/.openclaw/workspace"

def docx_to_txt(docx_path, txt_path):
    try:
        text = []
        with zipfile.ZipFile(docx_path) as docx:
            xml_content = docx.read('word/document.xml')
            root = ET.fromstring(xml_content)
            for paragraph in root.iter('{http://schemas.openxmlformats.org/wordprocessingml/2006/main}p'):
                p_text = []
                for run in paragraph.iter('{http://schemas.openxmlformats.org/wordprocessingml/2006/main}t'):
                    if run.text:
                        p_text.append(run.text)
                text.append("".join(p_text))
        with open(txt_path, 'w', encoding='utf-8') as f:
            f.write("\n".join(text))
        print(f"[✔] Converted docx: {docx_path} -> {txt_path}")
    except Exception as e:
        print(f"[Err] Failed to convert docx {docx_path}: {e}")

def pptx_to_txt(pptx_path, txt_path):
    try:
        text = []
        with zipfile.ZipFile(pptx_path) as pptx:
            slide_files = [f for f in pptx.namelist() if f.startswith('ppt/slides/slide') and f.endswith('.xml')]
            slide_files.sort(key=lambda x: int(re.search(r'\d+', x).group()))
            for slide_file in slide_files:
                slide_text = []
                xml_content = pptx.read(slide_file)
                root = ET.fromstring(xml_content)
                for t in root.iter('{http://schemas.openxmlformats.org/drawingml/2006/main}t'):
                    if t.text:
                        slide_text.append(t.text)
                slide_num = re.search(r'\d+', slide_file).group()
                text.append(f"--- Slide {slide_num} ---\n" + "\n".join(slide_text))
        with open(txt_path, 'w', encoding='utf-8') as f:
            f.write("\n\n".join(text))
        print(f"[✔] Converted pptx: {pptx_path} -> {txt_path}")
    except Exception as e:
        print(f"[Err] Failed to convert pptx {pptx_path}: {e}")

def main():
    print(f"Starting Office File Watcher on {WATCH_DIR}...")
    processed_files = set()
    
    # Ensure directories exist
    os.makedirs(WATCH_DIR, exist_ok=True)
    os.makedirs(DEST_DIR, exist_ok=True)
    
    # Initial scan to skip already existing files
    for root_dir, dirs, files in os.walk(WATCH_DIR):
        for file in files:
            if file.endswith(('.docx', '.pptx', '.pdf')):
                processed_files.add(os.path.join(root_dir, file))
                
    while True:
        try:
            for root_dir, dirs, files in os.walk(WATCH_DIR):
                for file in files:
                    filepath = os.path.join(root_dir, file)
                    if file.endswith(('.docx', '.pptx', '.pdf')) and filepath not in processed_files:
                        # Wait a bit to ensure file is fully written
                        time.sleep(2)
                        
                        # Determine extension
                        ext = ""
                        if file.endswith('.docx'):
                            ext = "docx"
                        elif file.endswith('.pptx'):
                            ext = "pptx"
                        elif file.endswith('.pdf'):
                            ext = "pdf"
                            
                        # Clean old thesis files in destination workspace to avoid stale analysis
                        for old_file in os.listdir(DEST_DIR):
                            if old_file.startswith("thesis."):
                                try:
                                    os.remove(os.path.join(DEST_DIR, old_file))
                                except Exception as e:
                                    print(f"[Err] Failed to delete old file {old_file}: {e}")
                                    
                        # Copy to workspace as thesis.<ext>
                        dest_path = os.path.join(DEST_DIR, f"thesis.{ext}")
                        try:
                            shutil.copy2(filepath, dest_path)
                            print(f"[✔] Copied: {filepath} -> {dest_path}")
                        except Exception as e:
                            print(f"[Err] Failed to copy {filepath}: {e}")
                            
                        # Convert to txt if docx/pptx
                        if ext in ('docx', 'pptx'):
                            txt_path = os.path.join(DEST_DIR, f"thesis.{ext}.txt")
                            if ext == 'docx':
                                docx_to_txt(dest_path, txt_path)
                            elif ext == 'pptx':
                                pptx_to_txt(dest_path, txt_path)
                                
                        processed_files.add(filepath)
            time.sleep(5)
        except KeyboardInterrupt:
            break
        except Exception as e:
            print(f"Error in main loop: {e}")
            time.sleep(5)

if __name__ == "__main__":
    main()
