#!/usr/bin/env python3

import sys
import requests
from bs4 import BeautifulSoup
import re
import json
import time
import sqlite3
import os

# Add debug flag to control output verbosity
DEBUG = False  # Set to True for verbose debugging output

# Helper function to print only when debugging is enabled
def debug_print(*args, **kwargs):
    if DEBUG:
        print(*args, **kwargs)

# Initialize SQLite database for storing known BPMs
DB_FILE = "known_bpms.sqlite"

def init_database():
    """Initialize the SQLite database if it doesn't exist"""
    if not os.path.exists(DB_FILE):
        print(f"Creating new BPM database at {DB_FILE}")
        conn = sqlite3.connect(DB_FILE)
        cursor = conn.cursor()
        
        # Create table for storing BPMs
        cursor.execute('''
        CREATE TABLE known_bpms (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            artist TEXT NOT NULL,
            track TEXT NOT NULL,
            bpm TEXT NOT NULL,
            source TEXT,
            timestamp INTEGER,
            UNIQUE(artist, track)
        )
        ''')
        
        conn.commit()
        conn.close()
        print(f"Database initialized")

def get_bpm_from_songbpm(artist, track):
    """Get track BPM by scraping songbpm.com"""
    # Try multiple URL formats for songbpm.com
    artist_dash = artist.lower().replace(' ', '-')
    track_dash = track.lower().replace(' ', '-')
    
    # Replace spaces with '+' for alternative URL format
    artist_plus = artist.lower().replace(' ', '+')
    track_plus = track.lower().replace(' ', '+')
    
    urls = [
        f"https://songbpm.com/@{artist_dash}/{track_dash}",
        f"https://songbpm.com/{artist_plus}/{track_plus}"
    ]
    
    # Add headers to simulate a browser
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.5',
        'Referer': 'https://songbpm.com/',
        'DNT': '1',
        'Connection': 'keep-alive',
        'Upgrade-Insecure-Requests': '1',
        'Cache-Control': 'max-age=0'
    }
    
    for url in urls:
        debug_print(f"Looking up BPM on songbpm.com: {url}")
        
        try:
            response = requests.get(url, headers=headers)
            debug_print(f"Status code: {response.status_code}")
            
            if response.status_code == 200:
                # Parse the HTML
                soup = BeautifulSoup(response.text, 'html.parser')
                
                # Method 1: Look for the BPM directly in the HTML (main display)
                bpm_element = soup.select_one('.bpm-value, h1 + div')
                if bpm_element:
                    bpm_text = bpm_element.text.strip()
                    # Extract number from text like "117 BPM"
                    bpm_match = re.search(r'(\d+)', bpm_text)
                    if bpm_match:
                        bpm = bpm_match.group(1)
                        debug_print(f"Found BPM in HTML: {bpm}")
                        # Save to database
                        save_bpm_to_db(artist, track, bpm, "songbpm")
                        return bpm
                
                # Method 2: Look for BPM in song metrics section
                metrics = soup.select('div.song-metrics, .song-metrics')
                for metric in metrics:
                    if 'Tempo (BPM)' in metric.text:
                        bpm_text = metric.text
                        bpm_match = re.search(r'Tempo \(BPM\)[^\d]*(\d+)', bpm_text)
                        if bpm_match:
                            bpm = bpm_match.group(1)
                            debug_print(f"Found BPM in metrics: {bpm}")
                            # Save to database
                            save_bpm_to_db(artist, track, bpm, "songbpm")
                            return bpm
                
                # Method 3: Extract BPM from JSON-LD structured data
                scripts = soup.find_all('script', {'type': 'application/ld+json'})
                for script in scripts:
                    try:
                        data = json.loads(script.string)
                        if 'tempo' in data:
                            bpm = data['tempo']
                            debug_print(f"Found BPM in JSON-LD: {bpm}")
                            # Save to database
                            save_bpm_to_db(artist, track, bpm, "songbpm")
                            return bpm
                    except (json.JSONDecodeError, AttributeError):
                        continue
                
                # Method 4: Extract BPM from any text that looks like "123 BPM"
                bpm_pattern = re.compile(r'(\d+)\s*BPM', re.IGNORECASE)
                matches = bpm_pattern.findall(response.text)
                if matches:
                    bpm = matches[0]
                    debug_print(f"Found BPM using regex: {bpm}")
                    # Save to database
                    save_bpm_to_db(artist, track, bpm, "songbpm")
                    return bpm
                
                debug_print("BPM not found on the page")
            else:
                debug_print(f"Failed to fetch data: HTTP {response.status_code}")
        
        except Exception as e:
            debug_print(f"Error: {e}")
    
    debug_print("BPM not found on songbpm.com")
    return None

def get_bpm_from_tunebat(artist, track):
    """Get track BPM by using the Tunebat API directly"""
    debug_print(f"Looking up BPM on Tunebat API for: {artist} - {track}")
    
    # Format the search query similar to the JS version
    query = f"{artist} {track}"
    encoded_query = requests.utils.quote(query)
    
    api_url = f"https://api.tunebat.com/api/tracks/search?term={encoded_query}"
    
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
        'Accept': 'application/json',
        'Referer': 'https://tunebat.com/',
    }
    
    try:
        response = requests.get(api_url, headers=headers)
        debug_print(f"API Status code: {response.status_code}")
        
        if response.status_code == 200:
            # Try to parse the JSON response
            try:
                # Normalize the response text as done in the JS version
                normalized_text = response.text
                data = json.loads(normalized_text)
                
                if 'data' in data and 'items' in data['data']:
                    items = data['data']['items']
                    
                    if not items:
                        debug_print("No results found in Tunebat API")
                        return None
                    
                    # Find the best match (first result is usually the best)
                    best_match = items[0]
                    
                    # Check if there's a better match by comparing artist and title
                    for item in items:
                        # In the JS code, 'as' contains artists and 'n' is the track title
                        if artist.lower() in [a.lower() for a in item.get('as', [])] and \
                           track.lower() == item.get('n', '').lower():
                            best_match = item
                            break
                    
                    # In the JS code, 'b' is the BPM field
                    if 'b' in best_match:
                        bpm = best_match['b']
                        debug_print(f"Found BPM in Tunebat API: {bpm}")
                        # Save to database
                        save_bpm_to_db(artist, track, str(bpm), "tunebat_api")
                        return str(bpm)
                    else:
                        debug_print("BPM field not found in the best match item")
                
                else:
                    debug_print("Invalid response format from Tunebat API")
            
            except json.JSONDecodeError as e:
                debug_print(f"Failed to parse Tunebat API response: {e}")
                # If we get rate limited, we might need to wait
                if 'Retry-After' in response.headers:
                    retry_after = int(response.headers['Retry-After'])
                    debug_print(f"Rate limited. Need to wait {retry_after} seconds before retrying")
                    # Could implement retry logic here
        
        elif response.status_code == 429:  # Too Many Requests
            debug_print("Rate limited by Tunebat API")
            if 'Retry-After' in response.headers:
                retry_after = int(response.headers['Retry-After'])
                debug_print(f"Need to wait {retry_after} seconds before retrying")
                # Could implement retry logic here
        
        else:
            debug_print(f"Tunebat API request failed with status code: {response.status_code}")
    
    except Exception as e:
        debug_print(f"Error with Tunebat API request: {e}")
    
    # Fallback to the web scraping method
    debug_print("Falling back to web scraping method")
    return get_bpm_from_tunebat_web_scraping(artist, track)

def get_bpm_from_tunebat_web_scraping(artist, track):
    """Get track BPM by scraping tunebat.com (fallback method)"""
    # Process the artist and track names
    artist_clean = artist.lower().replace(' ', '-')
    track_clean = track.lower().replace(' ', '-')
    
    # Remove special characters that might break the URL
    artist_clean = re.sub(r'[^\w\-]', '', artist_clean)
    track_clean = re.sub(r'[^\w\-]', '', track_clean)
    
    # Try different URL formats - Tunebat often formats URLs as "Track-Artist"
    urls = [
        f"https://tunebat.com/Info/{track_clean}-{artist_clean}",
        f"https://tunebat.com/Info/{artist_clean}-{track_clean}",
        f"https://tunebat.com/Info/{track_clean}/{artist_clean}",
        # Sometimes the URL includes the word "by" between track and artist
        f"https://tunebat.com/Info/{track_clean}-by-{artist_clean}"
    ]
    
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.5',
        'Referer': 'https://tunebat.com/',
        'DNT': '1',
        'Connection': 'keep-alive',
        'Upgrade-Insecure-Requests': '1',
        'Cache-Control': 'max-age=0'
    }
    
    for url in urls:
        debug_print(f"Looking up BPM on tunebat.com: {url}")
        
        try:
            response = requests.get(url, headers=headers)
            debug_print(f"Status code: {response.status_code}")
            
            if response.status_code == 200:
                # Save the HTML for debugging
                with open("tunebat_response.html", "w", encoding="utf-8") as f:
                    f.write(response.text)
                
                debug_print(f"Saved HTML response to tunebat_response.html")
                
                # Parse the HTML
                soup = BeautifulSoup(response.text, 'html.parser')
                
                # Print the title to confirm we're on the right page
                title = soup.title.text if soup.title else "No title found"
                debug_print(f"Page title: {title}")
                
                # Method 1: Look for BPM in the attributes table
                # Updated selector to be more specific and handle deprecated :contains
                try:
                    # First attempt - look for table rows containing "BPM"
                    rows = soup.select('div.row.attribute')
                    debug_print(f"Found {len(rows)} attribute rows")
                    for row in rows:
                        row_text = row.get_text()
                        debug_print(f"Row text: {row_text}")
                        if 'BPM' in row_text:
                            # Found the BPM row, now extract the number
                            value_element = row.select_one('div.attribute-value')
                            if value_element:
                                bpm = value_element.text.strip()
                                debug_print(f"Found BPM on Tunebat: {bpm}")
                                # Save to database
                                save_bpm_to_db(artist, track, bpm, "tunebat_web")
                                return bpm
                except Exception as e:
                    debug_print(f"Error with method 1: {e}")
                
                # Method 2: Try various CSS selectors that might contain the BPM
                selectors = [
                    '.attribute-value', 
                    '.bpm-value', 
                    '.tempo-value',
                    '.bpm',
                    '.tempo'
                ]
                
                for selector in selectors:
                    elements = soup.select(selector)
                    debug_print(f"Selector '{selector}' found {len(elements)} elements")
                    for element in elements:
                        text = element.text.strip()
                        debug_print(f"Element text: {text}")
                        # Check if it looks like a BPM number (typically 60-200)
                        if re.match(r'^\d+$', text) and 40 <= int(text) <= 220:
                            debug_print(f"Found BPM using selector {selector}: {text}")
                            # Save to database
                            save_bpm_to_db(artist, track, text, "tunebat_web")
                            return text
                
                # Method 3: Find any numbers near "BPM" text
                # Look through all page text for patterns like "120 BPM" or "BPM: 120"
                bpm_patterns = [
                    r'(\d+)\s*BPM',  # "120 BPM"
                    r'BPM\s*[:-]?\s*(\d+)',  # "BPM: 120" or "BPM - 120"
                    r'tempo\s*[:-]?\s*(\d+)',  # "Tempo: 120"
                    r'(\d+)\s*beats per minute'  # "120 beats per minute"
                ]
                
                for pattern in bpm_patterns:
                    matches = re.findall(pattern, response.text, re.IGNORECASE)
                    if matches:
                        debug_print(f"Pattern '{pattern}' found matches: {matches}")
                        bpm = matches[0]
                        debug_print(f"Found BPM using regex pattern {pattern}: {bpm}")
                        # Save to database
                        save_bpm_to_db(artist, track, bpm, "tunebat_web")
                        return bpm
            
            else:
                debug_print(f"Failed to fetch data from Tunebat: HTTP {response.status_code}")
        
        except Exception as e:
            debug_print(f"Error with Tunebat URL {url}: {e}")
    
    debug_print("BPM not found on any Tunebat URL")
    return None

def check_known_bpms(artist, track):
    """Check database for known BPMs"""
    init_database()  # Make sure database exists
    
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    
    # Query the database
    cursor.execute(
        "SELECT bpm FROM known_bpms WHERE LOWER(artist) = LOWER(?) AND LOWER(track) = LOWER(?)",
        (artist.lower(), track.lower())
    )
    result = cursor.fetchone()
    conn.close()
    
    if result:
        bpm = result[0]
        debug_print(f"Found BPM in known BPMs database: {bpm}")
        return bpm
    return None

def save_bpm_to_db(artist, track, bpm, source):
    """Save a found BPM to the database"""
    init_database()  # Make sure database exists
    
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    
    try:
        # Check if entry already exists
        cursor.execute(
            "SELECT id FROM known_bpms WHERE LOWER(artist) = LOWER(?) AND LOWER(track) = LOWER(?)",
            (artist.lower(), track.lower())
        )
        existing = cursor.fetchone()
        
        current_time = int(time.time())
        
        if existing:
            # Update existing entry
            cursor.execute(
                "UPDATE known_bpms SET bpm = ?, source = ?, timestamp = ? WHERE id = ?",
                (bpm, source, current_time, existing[0])
            )
            debug_print(f"Updated BPM in database for {artist} - {track}: {bpm}")
        else:
            # Insert new entry
            cursor.execute(
                "INSERT INTO known_bpms (artist, track, bpm, source, timestamp) VALUES (?, ?, ?, ?, ?)",
                (artist.lower(), track.lower(), bpm, source, current_time)
            )
            debug_print(f"Added new BPM to database for {artist} - {track}: {bpm}")
        
        conn.commit()
    except sqlite3.Error as e:
        debug_print(f"Database error: {e}")
    finally:
        conn.close()

def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <artist> <track>")
        sys.exit(1)
    
    artist = sys.argv[1]
    track = sys.argv[2]
    
    print(f"Looking up BPM for: {artist} - {track}")
    
    # First check if we already have this BPM in our database
    bpm = check_known_bpms(artist, track)
    
    # If not in database, try to get BPM from Tunebat API
    if not bpm:
        bpm = get_bpm_from_tunebat(artist, track)
    
    # If Tunebat fails, try Song BPM
    if not bpm:
        bpm = get_bpm_from_songbpm(artist, track)
    
    if bpm:
        print(f"BPM for '{artist} - {track}': {bpm}")
    else:
        print(f"Could not find BPM for '{artist} - {track}'")
        sys.exit(1)

if __name__ == "__main__":
    main() 