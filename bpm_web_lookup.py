#!/usr/bin/env python3

import sys
import requests
from bs4 import BeautifulSoup
import re
import json
import time
import sqlite3
import os
import logging
from typing import Optional, Dict, Any, List, Tuple

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler(sys.stderr)]
)
logger = logging.getLogger("bpm_lookup")

# Config
DB_FILE = "known_bpms.sqlite"
DEBUG = False  # Set to True for verbose debugging output

# Set log level based on debug flag
if DEBUG:
    logger.setLevel(logging.DEBUG)
else:
    logger.setLevel(logging.CRITICAL)

# API endpoints and URL templates
ENDPOINTS = {
    'tunebat_api': 'https://api.tunebat.com/api/tracks/search?term={query}',
    'songbpm_format1': 'https://songbpm.com/@{artist}/{track}',
    'songbpm_format2': 'https://songbpm.com/{artist}/{track}',
    'tunebat_format1': 'https://tunebat.com/Info/{track}-{artist}',
    'tunebat_format2': 'https://tunebat.com/Info/{artist}-{track}',
    'tunebat_format3': 'https://tunebat.com/Info/{track}/{artist}',
    'tunebat_format4': 'https://tunebat.com/Info/{track}-by-{artist}'
}

# Common HTTP headers
DEFAULT_HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.5',
    'DNT': '1',
    'Connection': 'keep-alive',
    'Upgrade-Insecure-Requests': '1',
    'Cache-Control': 'max-age=0'
}

def init_database() -> None:
    """Initialize the SQLite database if it doesn't exist"""
    if not os.path.exists(DB_FILE):
        logger.info(f"Creating new BPM database at {DB_FILE}")
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
        logger.info(f"Database initialized")

def make_http_request(url: str, headers: Dict = None, is_json: bool = False) -> Optional[Tuple[int, Any]]:
    """
    Make an HTTP request and return the response.
    
    Args:
        url: URL to request
        headers: Optional headers dictionary
        is_json: Whether to expect a JSON response
        
    Returns:
        Tuple of (status_code, content) where content is either text or parsed JSON
    """
    if headers is None:
        headers = DEFAULT_HEADERS
    
    try:
        logger.debug(f"Making request to: {url}")
        response = requests.get(url, headers=headers)
        logger.debug(f"Status code: {response.status_code}")
        
        if response.status_code == 200:
            if is_json:
                try:
                    return response.status_code, response.json()
                except json.JSONDecodeError as e:
                    logger.warning(f"Failed to parse JSON: {e}")
                    return response.status_code, response.text
            return response.status_code, response.text
        elif response.status_code == 429:  # Too Many Requests
            logger.warning("Rate limited by the server")
            if 'Retry-After' in response.headers:
                retry_after = int(response.headers['Retry-After'])
                logger.info(f"Need to wait {retry_after} seconds before retrying")
            return response.status_code, None
        else:
            logger.warning(f"Request failed with status code: {response.status_code}")
            return response.status_code, None
    
    except Exception as e:
        logger.error(f"Error making request: {e}")
        return None, None

def extract_bpm_from_html(html_content: str) -> Optional[str]:
    """
    Extract BPM value from HTML using various methods.
    
    Args:
        html_content: HTML content to parse
        
    Returns:
        BPM value as string if found, None otherwise
    """
    if not html_content:
        return None
    
    soup = BeautifulSoup(html_content, 'html.parser')
    
    # Method 1: Look for the BPM directly in the HTML (main display)
    bpm_element = soup.select_one('.bpm-value, h1 + div')
    if bpm_element:
        bpm_text = bpm_element.text.strip()
        # Extract number from text like "117 BPM"
        bpm_match = re.search(r'(\d+)', bpm_text)
        if bpm_match:
            return bpm_match.group(1)
    
    # Method 2: Look for BPM in song metrics section
    metrics = soup.select('div.song-metrics, .song-metrics')
    for metric in metrics:
        if 'Tempo (BPM)' in metric.text:
            bpm_text = metric.text
            bpm_match = re.search(r'Tempo \(BPM\)[^\d]*(\d+)', bpm_text)
            if bpm_match:
                return bpm_match.group(1)
    
    # Method 3: Extract BPM from JSON-LD structured data
    scripts = soup.find_all('script', {'type': 'application/ld+json'})
    for script in scripts:
        try:
            data = json.loads(script.string)
            if 'tempo' in data:
                return str(data['tempo'])
        except (json.JSONDecodeError, AttributeError):
            continue
    
    # Method 4: Extract BPM from any text that looks like "123 BPM"
    bpm_pattern = re.compile(r'(\d+)\s*BPM', re.IGNORECASE)
    matches = bpm_pattern.findall(html_content)
    if matches:
        return matches[0]
    
    return None

def check_known_bpms(artist: str, track: str) -> Optional[str]:
    """Check if BPM is already known in the database"""
    try:
        conn = sqlite3.connect(DB_FILE)
        cursor = conn.cursor()
        
        cursor.execute(
            "SELECT bpm FROM known_bpms WHERE LOWER(artist) = LOWER(?) AND LOWER(track) = LOWER(?)",
            (artist, track)
        )
        
        result = cursor.fetchone()
        conn.close()
        
        if result:
            logger.debug(f"Found BPM in database: {result[0]}")
            return result[0]
            
        logger.debug("BPM not found in database")
        return None
        
    except Exception as e:
        logger.error(f"Error checking database: {e}")
        return None

def save_bpm_to_db(artist: str, track: str, bpm: str, source: str) -> None:
    """Save the BPM to the database"""
    try:
        conn = sqlite3.connect(DB_FILE)
        cursor = conn.cursor()
        
        # Check if entry already exists
        cursor.execute(
            "SELECT id FROM known_bpms WHERE LOWER(artist) = LOWER(?) AND LOWER(track) = LOWER(?)",
            (artist, track)
        )
        
        if cursor.fetchone():
            # Update existing entry
            cursor.execute(
                "UPDATE known_bpms SET bpm = ?, source = ?, timestamp = ? WHERE LOWER(artist) = LOWER(?) AND LOWER(track) = LOWER(?)",
                (bpm, source, int(time.time()), artist, track)
            )
            logger.debug(f"Updated BPM in database: {bpm} for {artist} - {track}")
        else:
            # Insert new entry
            cursor.execute(
                "INSERT INTO known_bpms (artist, track, bpm, source, timestamp) VALUES (?, ?, ?, ?, ?)",
                (artist, track, bpm, source, int(time.time()))
            )
            logger.debug(f"Saved BPM to database: {bpm} for {artist} - {track}")
        
        conn.commit()
        conn.close()
        
    except Exception as e:
        logger.error(f"Error saving to database: {e}")

def get_bpm_from_songbpm(artist: str, track: str) -> Optional[str]:
    """Get track BPM by scraping songbpm.com"""
    # Format parameters for URL
    artist_dash = artist.lower().replace(' ', '-')
    track_dash = track.lower().replace(' ', '-')
    artist_plus = artist.lower().replace(' ', '+')
    track_plus = track.lower().replace(' ', '+')
    
    urls = [
        ENDPOINTS['songbpm_format1'].format(artist=artist_dash, track=track_dash),
        ENDPOINTS['songbpm_format2'].format(artist=artist_plus, track=track_plus)
    ]
    
    for url in urls:
        logger.debug(f"Looking up BPM on songbpm.com: {url}")
        status, content = make_http_request(url)
        
        if status == 200 and content:
            bpm = extract_bpm_from_html(content)
            if bpm:
                logger.debug(f"Found BPM on songbpm.com: {bpm}")
                save_bpm_to_db(artist, track, bpm, "songbpm")
                return bpm
    
    logger.debug("BPM not found on songbpm.com")
    return None

def get_bpm_from_tunebat_api(artist: str, track: str) -> Optional[str]:
    """Get track BPM by using the Tunebat API directly"""
    logger.debug(f"Looking up BPM on Tunebat API for: {artist} - {track}")
    
    # Format the search query
    query = f"{artist} {track}"
    encoded_query = requests.utils.quote(query)
    api_url = ENDPOINTS['tunebat_api'].format(query=encoded_query)
    
    # Use specific headers for API
    api_headers = DEFAULT_HEADERS.copy()
    api_headers['Accept'] = 'application/json'
    api_headers['Referer'] = 'https://tunebat.com/'
    
    status, data = make_http_request(api_url, headers=api_headers, is_json=True)
    
    if status == 200 and data:
        # Handle both parsed JSON and text response
        if isinstance(data, str):
            try:
                data = json.loads(data)
            except json.JSONDecodeError:
                logger.warning("Failed to parse Tunebat API response")
                return None
        
        if 'data' in data and 'items' in data['data']:
            items = data['data']['items']
            
            if not items:
                logger.debug("No results found in Tunebat API")
                return None
            
            # Find the best match (first result is usually the best)
            best_match = items[0]
            
            # Check if there's a better match by comparing artist and title
            for item in items:
                if artist.lower() in [a.lower() for a in item.get('as', [])] and \
                   track.lower() == item.get('n', '').lower():
                    best_match = item
                    break
            
            # In the API response, 'b' is the BPM field
            if 'b' in best_match:
                bpm = str(best_match['b'])
                logger.debug(f"Found BPM in Tunebat API: {bpm}")
                save_bpm_to_db(artist, track, bpm, "tunebat_api")
                return bpm
    
    # Fallback to web scraping method
    logger.debug("Falling back to web scraping method")
    return get_bpm_from_tunebat_web_scraping(artist, track)

def get_bpm_from_tunebat_web_scraping(artist: str, track: str) -> Optional[str]:
    """Get track BPM by scraping tunebat.com (fallback method)"""
    # Process the artist and track names
    artist_clean = artist.lower().replace(' ', '-')
    track_clean = track.lower().replace(' ', '-')
    
    # Remove special characters that might break the URL
    artist_clean = re.sub(r'[^\w\-]', '', artist_clean)
    track_clean = re.sub(r'[^\w\-]', '', track_clean)
    
    # Try different URL formats
    urls = [
        ENDPOINTS['tunebat_format1'].format(track=track_clean, artist=artist_clean),
        ENDPOINTS['tunebat_format2'].format(track=track_clean, artist=artist_clean),
        ENDPOINTS['tunebat_format3'].format(track=track_clean, artist=artist_clean),
        ENDPOINTS['tunebat_format4'].format(track=track_clean, artist=artist_clean)
    ]
    
    for url in urls:
        logger.debug(f"Looking up BPM on tunebat.com: {url}")
        status, content = make_http_request(url)
        
        if status == 200 and content:
            bpm = extract_bpm_from_html(content)
            if bpm:
                logger.debug(f"Found BPM on tunebat.com: {bpm}")
                save_bpm_to_db(artist, track, bpm, "tunebat_web")
                return bpm
    
    logger.debug("BPM not found on tunebat.com")
    return None

def get_track_bpm(artist: str, track: str) -> Optional[str]:
    """
    Main function to get BPM for a track using all available methods.
    
    Args:
        artist: Artist name
        track: Track name
        
    Returns:
        BPM as string if found, None otherwise
    """
    # Initialize the database if it doesn't exist
    init_database()
    
    # Check if we already have this BPM in our database
    known_bpm = check_known_bpms(artist, track)
    if known_bpm:
        return known_bpm
    
    # Try getting BPM from Tunebat API first (usually most reliable)
    bpm = get_bpm_from_tunebat_api(artist, track)
    if bpm:
        return bpm
    
    # Try getting BPM from Song BPM website
    bpm = get_bpm_from_songbpm(artist, track)
    if bpm:
        return bpm
    
    logger.info(f"Could not find BPM for {artist} - {track}")
    return None

def main():
    """Command-line interface for BPM lookup"""
    if len(sys.argv) < 3:
        print("Usage: python bpm_web_lookup.py <artist> <track>", file=sys.stderr)
        sys.exit(1)
    
    # Extract artist and track from command-line arguments
    artist = sys.argv[1]
    track = sys.argv[2]
    
    # Set debug mode if requested
    global DEBUG
    if len(sys.argv) > 3 and sys.argv[3].lower() in ['--debug', '-d']:
        DEBUG = True
        logger.setLevel(logging.DEBUG)
        logger.debug("Debug mode enabled")
    
    bpm = get_track_bpm(artist, track)
    
    if bpm:
        # Print only the BPM value with no extra characters
        sys.stdout.write(bpm.strip())
        sys.stdout.flush()
        sys.exit(0)
    else:
        sys.stderr.write("BPM not found")
        sys.stderr.flush()
        sys.exit(1)

if __name__ == "__main__":
    main() 