use std::path::Path;

pub struct WalkDir {
    queue: Vec<Box<Path>>,
}

impl WalkDir {
    pub fn new<T>(path: T) -> Self
    where
        T: AsRef<Path>,
    {
        WalkDir {
            queue: vec![Box::from(path.as_ref())],
        }
    }
}

impl Iterator for WalkDir {
    type Item = Box<Path>;
    fn next(&mut self) -> Option<Self::Item> {
        while let Some(element) = self.queue.pop() {
            if !element.is_dir() {
                return Some(element.clone());
            };
            let dir = std::fs::read_dir(element).unwrap();
            for each in dir {
                let each = each.unwrap();
                let p: Box<Path> = Box::from(each.path());
                self.queue.insert(0, p);
            }
        }
        None
    }
}

#[cfg(test)]
mod test {
    use std::{path::PathBuf, str::FromStr};

    use super::*;

    #[test]
    pub fn test_walkdir() {
        let wd = WalkDir::new("../ideapad");
        for file in wd {
            println!("{:?}", file);
        }
    }
}
